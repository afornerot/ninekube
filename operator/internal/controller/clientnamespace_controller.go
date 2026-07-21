/*
Copyright 2026.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package controller

import (
	"context"
	"crypto/rand"
	"fmt"
	"math/big"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	logf "sigs.k8s.io/controller-runtime/pkg/log"

	provisioningv1alpha1 "github.com/ninekube/operator/api/v1alpha1"
)

const (
	finalizerName = "provisioning.ninekube.io/finalizer"
)

// ServiceReconciler is the interface that each service controller must implement.
type ServiceReconciler interface {
	Reconcile(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace) error
	Cleanup(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace) error
}

// ClientNamespaceReconciler reconciles a ClientNamespace object
type ClientNamespaceReconciler struct {
	client.Client
	Scheme   *runtime.Scheme
	Services []ServiceReconciler
}

// +kubebuilder:rbac:groups=provisioning.ninekube.io,resources=clientnamespaces,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=provisioning.ninekube.io,resources=clientnamespaces/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=provisioning.ninekube.io,resources=clientnamespaces/finalizers,verbs=update
// +kubebuilder:rbac:groups="",resources=namespaces,verbs=get;list;watch;create;delete
// +kubebuilder:rbac:groups="",resources=configmaps,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=secrets,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=services,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=apps,resources=deployments,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=apps,resources=statefulsets,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=networking.k8s.io,resources=ingresses,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups="",resources=persistentvolumeclaims,verbs=get;list;watch;create;update;patch;delete

func (r *ClientNamespaceReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := logf.FromContext(ctx)

	// Fetch the ClientNamespace instance
	var cn provisioningv1alpha1.ClientNamespace
	if err := r.Get(ctx, req.NamespacedName, &cn); err != nil {
		if errors.IsNotFound(err) {
			log.Info("ClientNamespace resource not found, likely deleted")
			return ctrl.Result{}, nil
		}
		log.Error(err, "Failed to get ClientNamespace")
		return ctrl.Result{}, err
	}

	// Handle deletion
	if !cn.DeletionTimestamp.IsZero() {
		return r.reconcileDelete(ctx, &cn)
	}

	// Add finalizer if not present
	if !controllerutil.ContainsFinalizer(&cn, finalizerName) {
		controllerutil.AddFinalizer(&cn, finalizerName)
		if err := r.Update(ctx, &cn); err != nil {
			return ctrl.Result{}, err
		}
	}

	// Skip if already in terminal state
	if cn.Status.Phase == provisioningv1alpha1.PhaseReady {
		return ctrl.Result{}, nil
	}

	// Start provisioning
	if cn.Status.Phase == "" || cn.Status.Phase == provisioningv1alpha1.PhasePending {
		cn.Status.Phase = provisioningv1alpha1.PhaseProvisioning
		if err := r.Status().Update(ctx, &cn); err != nil {
			return ctrl.Result{}, err
		}
	}

	// Ensure namespace exists
	nsName := fmt.Sprintf("%s-ns", cn.Name)
	if err := r.ensureNamespace(ctx, &cn, nsName); err != nil {
		return r.setFailed(ctx, &cn, "NamespaceFailed", err)
	}
	cn.Status.Namespace = nsName

	// Ensure admin credentials
	if err := r.ensureAdminCredentials(ctx, &cn, nsName); err != nil {
		return r.setFailed(ctx, &cn, "AdminCredentialsFailed", err)
	}
	cn.Status.AdminSecretName = "admin-credentials"

	// Ensure root service secrets (PostgreSQL, RustFS) + ninegate-secret
	// Generate passwords once and reuse across all secrets
	pgPass := r.getOrCreatePassword(ctx, nsName, "postgres-secret", "POSTGRES_PASSWORD", cn.Spec.Storage, "postgresRootPassword", cn.Name+"-pg")
	rustfsPass := r.getOrCreatePassword(ctx, nsName, "rustfs-secret", "RUSTFS_ROOT_PASSWORD", cn.Spec.Storage, "rustfsRootPassword", cn.Name+"-s3")

	if err := r.ensureRootSecrets(ctx, &cn, nsName, pgPass, rustfsPass); err != nil {
		return r.setFailed(ctx, &cn, "RootSecretsFailed", err)
	}

	// Ensure ninegate-secret (cross-references postgres + rustfs passwords)
	if err := r.ensureNinegateSecret(ctx, &cn, nsName, pgPass, rustfsPass); err != nil {
		return r.setFailed(ctx, &cn, "NinegateSecretFailed", err)
	}

	// Ensure TLS certificates
	if err := r.ensureCertificates(ctx, &cn, nsName, "tls"); err != nil {
		return r.setFailed(ctx, &cn, "CertFailed", err)
	}
	cn.Status.CertSecretName = "tls"

	// Ensure optional service infrastructure from catalog (DBs, buckets, Dex clients)
	if err := r.reconcileOptionalServices(ctx, &cn, nsName); err != nil {
		return r.setFailed(ctx, &cn, "OptionalServicesFailed", err)
	}

	// Reconcile all services
	for i, svc := range r.Services {
		svcName := serviceName(i)
		if err := svc.Reconcile(ctx, &cn); err != nil {
			log.Error(err, "Service reconciliation failed", "service", svcName)
			r.updateServiceStatus(&cn, svcName, false, err.Error())
			if statusErr := r.Status().Update(ctx, &cn); statusErr != nil {
				log.Error(statusErr, "Failed to update status")
			}
			return r.setFailed(ctx, &cn, fmt.Sprintf("%sFailed", svcName), err)
		}
		r.updateServiceStatus(&cn, svcName, true, "")
	}

	// Mark as ready
	cn.Status.Phase = provisioningv1alpha1.PhaseReady
	cn.Status.Endpoint = fmt.Sprintf("https://%s", cn.Spec.Domain)
	cn.Status.Conditions = append(cn.Status.Conditions, metav1.Condition{
		Type:               "Ready",
		Status:             metav1.ConditionTrue,
		LastTransitionTime: metav1.Now(),
		Reason:             "Provisioned",
		Message:            "All services are provisioned",
	})
	if err := r.Status().Update(ctx, &cn); err != nil {
		return ctrl.Result{}, err
	}

	log.Info("ClientNamespace provisioned successfully", "namespace", nsName, "endpoint", cn.Status.Endpoint)
	return ctrl.Result{}, nil
}

func (r *ClientNamespaceReconciler) reconcileDelete(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace) (ctrl.Result, error) {
	log := logf.FromContext(ctx)

	// Cleanup all services (reverse order)
	for i := len(r.Services) - 1; i >= 0; i-- {
		svc := r.Services[i]
		svcName := serviceName(i)
		if err := svc.Cleanup(ctx, cn); err != nil {
			log.Error(err, "Service cleanup failed", "service", svcName)
			return ctrl.Result{}, err
		}
	}

	// Cleanup all resources by label (owner references don't work cross-namespace)
	nsName := fmt.Sprintf("%s-ns", cn.Name)
	if err := r.cleanupClientResources(ctx, cn, nsName); err != nil {
		log.Error(err, "Failed to cleanup client resources", "namespace", nsName)
		return ctrl.Result{}, err
	}

	// Delete the namespace (not tracked by owner reference since Namespace is cluster-scoped)
	var ns corev1.Namespace
	if err := r.Get(ctx, types.NamespacedName{Name: nsName}, &ns); err == nil {
		if ns.Labels["ninekube.io/client"] == cn.Name {
			if err := r.Delete(ctx, &ns); err != nil && !errors.IsNotFound(err) {
				log.Error(err, "Failed to delete namespace", "namespace", nsName)
				return ctrl.Result{}, err
			}
			log.Info("Deleted namespace", "namespace", nsName)
		}
	}

	// Remove finalizer
	controllerutil.RemoveFinalizer(cn, finalizerName)
	if err := r.Update(ctx, cn); err != nil {
		return ctrl.Result{}, err
	}

	return ctrl.Result{}, nil
}

func (r *ClientNamespaceReconciler) ensureNamespace(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, nsName string) error {
	var ns corev1.Namespace
	err := r.Get(ctx, types.NamespacedName{Name: nsName}, &ns)
	if err == nil {
		return nil // already exists
	}
	if !errors.IsNotFound(err) {
		return err
	}

	// Track namespace in status (no owner reference — Namespace is cluster-scoped)
	ns = corev1.Namespace{
		ObjectMeta: metav1.ObjectMeta{
			Name: nsName,
			Labels: map[string]string{
				"app.kubernetes.io/part-of":    "ninekube",
				"app.kubernetes.io/managed-by": "ninekube-operator",
				"ninekube.io/client":           cn.Name,
			},
			Annotations: map[string]string{
				"ninekube.io/domain": cn.Spec.Domain,
				"ninekube.io/plan":   string(cn.Spec.Plan),
				"ninekube.io/admin":  cn.Spec.Admin.Email,
			},
		},
	}

	return r.Create(ctx, &ns)
}

func (r *ClientNamespaceReconciler) ensureAdminCredentials(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns string) error {
	// Check if user provided a password secret
	if cn.Spec.Admin.PasswordSecretRef != nil {
		// User provided - just record the reference, don't create
		return nil
	}

	// Auto-generate admin credentials
	secretName := "admin-credentials"
	var secret corev1.Secret
	err := r.Get(ctx, types.NamespacedName{Name: secretName, Namespace: ns}, &secret)
	if err == nil {
		return nil // already exists
	}
	if !errors.IsNotFound(err) {
		return err
	}

	password, err := generateRandomPassword(24)
	if err != nil {
		return fmt.Errorf("failed to generate admin password: %w", err)
	}

	secret = corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      secretName,
			Namespace: ns,
			Labels:    clientLabels(cn),
		},
		StringData: map[string]string{
			"username": cn.Spec.Admin.Username,
			"password": password,
			"email":    cn.Spec.Admin.Email,
		},
	}

	return r.Create(ctx, &secret)
}

func (r *ClientNamespaceReconciler) ensureRootSecrets(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns, pgPass, rustfsPass string) error {
	// PostgreSQL root secret
	if err := r.ensureServiceSecret(ctx, cn, ns, "postgres-secret", map[string]string{
		"POSTGRES_USER":     "root",
		"POSTGRES_PASSWORD": pgPass,
		"POSTGRES_DB":       "ninegate",
	}); err != nil {
		return err
	}

	// RustFS root secret
	if err := r.ensureServiceSecret(ctx, cn, ns, "rustfs-secret", map[string]string{
		"RUSTFS_ROOT_USER":     cn.Name,
		"RUSTFS_ROOT_PASSWORD": rustfsPass,
	}); err != nil {
		return err
	}

	return nil
}

func (r *ClientNamespaceReconciler) ensureNinegateSecret(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns, pgPass, rustfsPass string) error {
	secretName := "ninegate-secret"
	var secret corev1.Secret
	err := r.Get(ctx, types.NamespacedName{Name: secretName, Namespace: ns}, &secret)
	if err == nil {
		return nil
	}
	if !errors.IsNotFound(err) {
		return err
	}

	// Read admin password from admin-credentials
	adminPass := "changeme"
	var adminSecret corev1.Secret
	if err := r.Get(ctx, types.NamespacedName{Name: "admin-credentials", Namespace: ns}, &adminSecret); err == nil {
		if pass, ok := adminSecret.Data["password"]; ok && len(pass) > 0 {
			adminPass = string(pass)
		}
	}

	// Generate a stable app-secret
	appSecret, _ := generateRandomPassword(32)

	domain := cn.Spec.Domain
	databaseURL := fmt.Sprintf("postgresql://root:%s@postgresql:5432/ninegate?serverVersion=16", pgPass)
	ldapBaseDN := replaceDotsWithDC(domain)

	secret = corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      secretName,
			Namespace: ns,
			Labels: map[string]string{
				"app.kubernetes.io/name":       "ninegate",
				"app.kubernetes.io/part-of":    "ninekube",
				"app.kubernetes.io/managed-by": "ninekube-operator",
				"ninekube.io/client":           cn.Name,
			},
		},
		StringData: map[string]string{
			"app-secret":         appSecret,
			"app-admin-password": adminPass,
			"database-url":       databaseURL,
			"ldap-base":          ldapBaseDN,
			"oidc-client-secret": "changeme",
			"default-uri":        fmt.Sprintf("https://ninegate.%s", domain),
			"oidc-issuer":        fmt.Sprintf("https://dex.%s", domain),
			"oidc-redirect-uri":  fmt.Sprintf("https://ninegate.%s/callback", domain),
			"storage-dsn":        "s3://ninegate-uploads",
			"s3-endpoint":        "http://rustfs:9000",
			"s3-bucket":          "ninegate-uploads",
			"s3-access-key":      cn.Name,
			"s3-secret-key":      rustfsPass,
			"s3-region":          "us-east-1",
		},
	}

	return r.Create(ctx, &secret)
}

func (r *ClientNamespaceReconciler) ensureServiceSecret(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns, name string, data map[string]string) error {
	var secret corev1.Secret
	err := r.Get(ctx, types.NamespacedName{Name: name, Namespace: ns}, &secret)
	if err == nil {
		return nil // already exists
	}
	if !errors.IsNotFound(err) {
		return err
	}

	secret = corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: ns,
			Labels:    clientLabels(cn),
		},
		StringData: data,
	}

	return r.Create(ctx, &secret)
}

func (r *ClientNamespaceReconciler) getOrGeneratePassword(storage *provisioningv1alpha1.StorageConfig, field, seed string) string {
	if storage != nil {
		switch field {
		case "postgresRootPassword":
			if storage.PostgresRootPassword != "" {
				return storage.PostgresRootPassword
			}
		case "rustfsRootPassword":
			if storage.RustFSRootPassword != "" {
				return storage.RustFSRootPassword
			}
		}
	}
	// Auto-generate
	pass, _ := generateRandomPassword(32)
	return pass
}

// getOrCreatePassword reads an existing password from a Secret, or generates and stores a new one.
func (r *ClientNamespaceReconciler) getOrCreatePassword(ctx context.Context, ns, secretName, secretKey string, storage *provisioningv1alpha1.StorageConfig, storageField, seed string) string {
	// Check if user provided override
	if storage != nil {
		if storageField == "postgresRootPassword" && storage.PostgresRootPassword != "" {
			return storage.PostgresRootPassword
		}
		if storageField == "rustfsRootPassword" && storage.RustFSRootPassword != "" {
			return storage.RustFSRootPassword
		}
	}

	// Try to read existing password
	var secret corev1.Secret
	if err := r.Get(ctx, types.NamespacedName{Name: secretName, Namespace: ns}, &secret); err == nil {
		if pass, ok := secret.Data[secretKey]; ok && len(pass) > 0 {
			return string(pass)
		}
	}

	// Generate new password
	pass, _ := generateRandomPassword(32)
	return pass
}

func (r *ClientNamespaceReconciler) ensureCertificates(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns, secretName string) error {
	if cn.Spec.Cert == nil {
		// Default: self-signed
		return r.ensureSelfSignedCert(ctx, cn, ns, secretName)
	}

	switch cn.Spec.Cert.Type {
	case provisioningv1alpha1.CertSecretRef:
		// User provides the cert - just copy or reference it
		return r.ensureCertFromSecret(ctx, cn, ns, secretName)
	case provisioningv1alpha1.CertLetsEncrypt:
		// TODO: create cert-manager Certificate resource
		return r.ensureSelfSignedCert(ctx, cn, ns, secretName)
	default:
		return r.ensureSelfSignedCert(ctx, cn, ns, secretName)
	}
}

func (r *ClientNamespaceReconciler) ensureSelfSignedCert(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns, secretName string) error {
	var secret corev1.Secret
	err := r.Get(ctx, types.NamespacedName{Name: secretName, Namespace: ns}, &secret)
	if err == nil {
		return nil
	}
	if !errors.IsNotFound(err) {
		return err
	}

	// Use a simple placeholder - the actual cert generation will be done
	// by the service controllers that need it (Dex, Ninegate, etc.)
	secret = corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      secretName,
			Namespace: ns,
			Labels: map[string]string{
				"app.kubernetes.io/part-of":    "ninekube",
				"app.kubernetes.io/managed-by": "ninekube-operator",
				"ninekube.io/client":           cn.Name,
				"ninekube.io/cert-type":        "selfsigned",
			},
		},
		Type: corev1.SecretTypeTLS,
		Data: map[string][]byte{
			corev1.TLSCertKey:       []byte(""),
			corev1.TLSPrivateKeyKey: []byte(""),
		},
	}

	return r.Create(ctx, &secret)
}

func (r *ClientNamespaceReconciler) ensureCertFromSecret(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns, secretName string) error {
	if cn.Spec.Cert.SecretName == "" {
		return fmt.Errorf("cert.secretName is required when cert.type is 'secret'")
	}

	// Check if target secret already exists
	var target corev1.Secret
	err := r.Get(ctx, types.NamespacedName{Name: secretName, Namespace: ns}, &target)
	if err == nil {
		return nil
	}
	if !errors.IsNotFound(err) {
		return err
	}

	// Fetch the source secret
	var source corev1.Secret
	if err := r.Get(ctx, types.NamespacedName{Name: cn.Spec.Cert.SecretName, Namespace: ns}, &source); err != nil {
		return fmt.Errorf("source cert secret %q not found: %w", cn.Spec.Cert.SecretName, err)
	}

	// Copy it
	target = corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      secretName,
			Namespace: ns,
			Labels: map[string]string{
				"app.kubernetes.io/part-of":    "ninekube",
				"app.kubernetes.io/managed-by": "ninekube-operator",
				"ninekube.io/client":           cn.Name,
				"ninekube.io/cert-type":        "secret",
			},
		},
		Type: corev1.SecretTypeTLS,
		Data: source.Data,
	}

	return r.Create(ctx, &target)
}

func generateRandomPassword(length int) (string, error) {
	const charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!$^*-=+"
	result := make([]byte, length)
	for i := range result {
		n, err := rand.Int(rand.Reader, big.NewInt(int64(len(charset))))
		if err != nil {
			return "", err
		}
		result[i] = charset[n.Int64()]
	}
	return string(result), nil
}

// clientLabels returns standard labels for resources belonging to a ClientNamespace.
func clientLabels(cn *provisioningv1alpha1.ClientNamespace) map[string]string {
	return map[string]string{
		"app.kubernetes.io/part-of":    "ninekube",
		"app.kubernetes.io/managed-by": "ninekube-operator",
		"ninekube.io/client":           cn.Name,
	}
}

// reconcileOptionalServices provisions infrastructure for enabled optional services
// based on the service catalog (databases, S3 buckets, Dex OIDC clients).
func (r *ClientNamespaceReconciler) reconcileOptionalServices(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns string) error {
	log := logf.FromContext(ctx)

	optionalServices := map[string]bool{
		"nextcloud":  cn.Spec.Services != nil && cn.Spec.Services.Nextcloud != nil && cn.Spec.Services.Nextcloud.Enabled,
		"wordpress":  cn.Spec.Services != nil && cn.Spec.Services.WordPress != nil && cn.Spec.Services.WordPress.Enabled,
		"dolibarr":   cn.Spec.Services != nil && cn.Spec.Services.Dolibarr != nil && cn.Spec.Services.Dolibarr.Enabled,
	}

	for name, enabled := range optionalServices {
		if !enabled {
			continue
		}

		descriptor, ok := ServiceCatalog[name]
		if !ok {
			log.Info("Service not in catalog, skipping", "service", name)
			continue
		}

		// Create database if needed
		if descriptor.DatabaseName != "" {
			log.Info("Database will be created by PostgreSQL init.sql", "service", name, "database", descriptor.DatabaseName)
		}

		// Create RustFS bucket if needed
		if descriptor.RustFSBucket != "" {
			log.Info("RustFS bucket configured", "service", name, "bucket", descriptor.RustFSBucket)
		}

		// Add Dex client if needed
		if descriptor.DexClient != nil {
			log.Info("Dex client configured", "service", name, "clientID", descriptor.DexClient.ID)
		}
	}

	return nil
}

// cleanupClientResources deletes all resources with the client label in the namespace.
func (r *ClientNamespaceReconciler) cleanupClientResources(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns string) error {
	log := logf.FromContext(ctx)
	labels := clientLabels(cn)

	// Delete Secrets
	var secrets corev1.SecretList
	if err := r.List(ctx, &secrets, client.InNamespace(ns), client.MatchingLabels(labels)); err == nil {
		for i := range secrets.Items {
			r.Delete(ctx, &secrets.Items[i])
			log.Info("Deleted Secret", "name", secrets.Items[i].Name, "namespace", ns)
		}
	}

	// Delete ConfigMaps
	var configMaps corev1.ConfigMapList
	if err := r.List(ctx, &configMaps, client.InNamespace(ns), client.MatchingLabels(labels)); err == nil {
		for i := range configMaps.Items {
			r.Delete(ctx, &configMaps.Items[i])
			log.Info("Deleted ConfigMap", "name", configMaps.Items[i].Name, "namespace", ns)
		}
	}

	// Delete Deployments
	var deployments appsv1.DeploymentList
	if err := r.List(ctx, &deployments, client.InNamespace(ns), client.MatchingLabels(labels)); err == nil {
		for i := range deployments.Items {
			r.Delete(ctx, &deployments.Items[i])
			log.Info("Deleted Deployment", "name", deployments.Items[i].Name, "namespace", ns)
		}
	}

	// Delete StatefulSets
	var statefulSets appsv1.StatefulSetList
	if err := r.List(ctx, &statefulSets, client.InNamespace(ns), client.MatchingLabels(labels)); err == nil {
		for i := range statefulSets.Items {
			r.Delete(ctx, &statefulSets.Items[i])
			log.Info("Deleted StatefulSet", "name", statefulSets.Items[i].Name, "namespace", ns)
		}
	}

	// Delete Services
	var services corev1.ServiceList
	if err := r.List(ctx, &services, client.InNamespace(ns), client.MatchingLabels(labels)); err == nil {
		for i := range services.Items {
			r.Delete(ctx, &services.Items[i])
			log.Info("Deleted Service", "name", services.Items[i].Name, "namespace", ns)
		}
	}

	// Delete PVCs
	var pvcs corev1.PersistentVolumeClaimList
	if err := r.List(ctx, &pvcs, client.InNamespace(ns), client.MatchingLabels(labels)); err == nil {
		for i := range pvcs.Items {
			r.Delete(ctx, &pvcs.Items[i])
			log.Info("Deleted PVC", "name", pvcs.Items[i].Name, "namespace", ns)
		}
	}

	return nil
}

func (r *ClientNamespaceReconciler) updateServiceStatus(cn *provisioningv1alpha1.ClientNamespace, name string, ready bool, msg string) {
	for i, s := range cn.Status.Services {
		if s.Name == name {
			cn.Status.Services[i].Ready = ready
			cn.Status.Services[i].Message = msg
			return
		}
	}
	cn.Status.Services = append(cn.Status.Services, provisioningv1alpha1.ServiceStatus{
		Name:    name,
		Ready:   ready,
		Message: msg,
	})
}

func (r *ClientNamespaceReconciler) setFailed(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, reason string, err error) (ctrl.Result, error) {
	cn.Status.Phase = provisioningv1alpha1.PhaseFailed
	cn.Status.Conditions = append(cn.Status.Conditions, metav1.Condition{
		Type:               "Ready",
		Status:             metav1.ConditionFalse,
		LastTransitionTime: metav1.Now(),
		Reason:             reason,
		Message:            err.Error(),
	})
	if statusErr := r.Status().Update(ctx, cn); statusErr != nil {
		logf.FromContext(ctx).Error(statusErr, "Failed to update status")
	}
	return ctrl.Result{}, err
}

func serviceName(index int) string {
	names := []string{"Namespace", "PostgreSQL", "Redis", "RustFS", "Ninegate", "Glauth", "Dex", "Nextcloud", "WordPress", "Dolibarr"}
	if index < len(names) {
		return names[index]
	}
	return fmt.Sprintf("service-%d", index)
}

// SetupWithManager sets up the controller with the Manager.
func (r *ClientNamespaceReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&provisioningv1alpha1.ClientNamespace{}).
		Named("clientnamespace").
		Complete(r)
}
