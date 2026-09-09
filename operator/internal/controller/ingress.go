package controller

import (
	"context"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/log"

	provisioningv1alpha1 "github.com/ninekube/operator/api/v1alpha1"
)

// ─── CA ────────────────────────────────────────────────────────────────────────

func (r *ClientNamespaceReconciler) ensureCA(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns string) error {
	secretName := "ca"
	var secret corev1.Secret
	err := r.Get(ctx, types.NamespacedName{Name: secretName, Namespace: ns}, &secret)
	if err == nil {
		return nil
	}
	if !errors.IsNotFound(err) {
		return err
	}

	ca, err := GenerateCA(fmt.Sprintf("%s-ca", cn.Name))
	if err != nil {
		return fmt.Errorf("failed to generate CA: %w", err)
	}

	secret = corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      secretName,
			Namespace: ns,
			Labels:    clientLabels(cn),
		},
		Type: corev1.SecretTypeTLS,
		Data: map[string][]byte{
			corev1.TLSCertKey:       ca.CertPEM,
			corev1.TLSPrivateKeyKey: ca.KeyPEM,
		},
	}

	return r.Create(ctx, &secret)
}

// getCA reads the CA from the secret.
func (r *ClientNamespaceReconciler) getCA(ctx context.Context, ns string) (*CA, error) {
	var secret corev1.Secret
	if err := r.Get(ctx, types.NamespacedName{Name: "ca", Namespace: ns}, &secret); err != nil {
		return nil, err
	}
	ca, err := ParseCA(secret.Data[corev1.TLSCertKey], secret.Data[corev1.TLSPrivateKeyKey])
	if err != nil {
		return nil, err
	}
	return ca, nil
}

// ─── SERVICE CERTS ─────────────────────────────────────────────────────────────

func (r *ClientNamespaceReconciler) ensureServiceCerts(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns string) error {
	ca, err := r.getCA(ctx, ns)
	if err != nil {
		return fmt.Errorf("failed to get CA: %w", err)
	}

	domain := cn.Spec.Domain

	// Services that need TLS certs
	type serviceCert struct {
		name    string
		service string
		extra   []string
	}

	certs := []serviceCert{
		{name: "ninegate-tls", service: "ninegate"},
		{name: "dex-tls", service: "dex"},
		{name: "rustfs-tls", service: "rustfs", extra: []string{fmt.Sprintf("s3.%s", domain)}},
		{name: "glauth-tls", service: "glauth"},
	}

	// Add optional service certs
	if cn.Spec.Services.Nextcloud != nil && cn.Spec.Services.Nextcloud.Enabled {
		certs = append(certs, serviceCert{name: "nextcloud-tls", service: "nextcloud"})
	}
	if cn.Spec.Services.WordPress != nil && cn.Spec.Services.WordPress.Enabled {
		certs = append(certs, serviceCert{name: "wordpress-tls", service: "wordpress"})
	}
	if cn.Spec.Services.Dolibarr != nil && cn.Spec.Services.Dolibarr.Enabled {
		certs = append(certs, serviceCert{name: "dolibarr-tls", service: "dolibarr"})
	}

	for _, sc := range certs {
		if err := r.ensureCertSecret(ctx, cn, ns, ca, sc.name, sc.service, domain, sc.extra); err != nil {
			return err
		}
	}

	return nil
}

func (r *ClientNamespaceReconciler) ensureCertSecret(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns string, ca *CA, secretName, service, domain string, extraDNS []string) error {
	var secret corev1.Secret
	err := r.Get(ctx, types.NamespacedName{Name: secretName, Namespace: ns}, &secret)
	if err == nil {
		return nil
	}
	if !errors.IsNotFound(err) {
		return err
	}

	certPEM, keyPEM, err := ca.SignCertMultiSAN(service, domain, extraDNS)
	if err != nil {
		return fmt.Errorf("failed to sign cert for %s: %w", service, err)
	}

	secret = corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      secretName,
			Namespace: ns,
			Labels:    clientLabels(cn),
		},
		Type: corev1.SecretTypeTLS,
		Data: map[string][]byte{
			corev1.TLSCertKey:       certPEM,
			corev1.TLSPrivateKeyKey: keyPEM,
		},
	}

	return r.Create(ctx, &secret)
}

// ─── INGRESSES ─────────────────────────────────────────────────────────────────

func (r *ClientNamespaceReconciler) ensureIngresses(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns string) error {
	log := log.FromContext(ctx)
	domain := cn.Spec.Domain
	issuerName := "letsencrypt-prod"
	if cn.Spec.Cert != nil && cn.Spec.Cert.Type == provisioningv1alpha1.CertSelfSigned {
		issuerName = ""
	}
	if cn.Spec.Cert != nil && cn.Spec.Cert.IssuerRef != "" {
		issuerName = cn.Spec.Cert.IssuerRef
	}

	type ingressDef struct {
		name    string
		host    string
		path    string
		port    int
		tls     string
	}

	ingresses := []ingressDef{
		{name: "ninegate", host: fmt.Sprintf("ninegate.%s", domain), path: "/", port: 80, tls: "ninegate-tls"},
		{name: "dex", host: fmt.Sprintf("dex.%s", domain), path: "/", port: 5556, tls: "dex-tls"},
		{name: "rustfs", host: fmt.Sprintf("rustfs.%s", domain), path: "/", port: 9001, tls: "rustfs-tls"},
		{name: "rustfs-api", host: fmt.Sprintf("s3.%s", domain), path: "/", port: 9000, tls: "rustfs-tls"},
	}

	if cn.Spec.Services.Nextcloud != nil && cn.Spec.Services.Nextcloud.Enabled {
		ingresses = append(ingresses, ingressDef{name: "nextcloud", host: fmt.Sprintf("nextcloud.%s", domain), path: "/", port: 80, tls: "nextcloud-tls"})
	}
	if cn.Spec.Services.WordPress != nil && cn.Spec.Services.WordPress.Enabled {
		ingresses = append(ingresses, ingressDef{name: "wordpress", host: fmt.Sprintf("wordpress.%s", domain), path: "/", port: 80, tls: "wordpress-tls"})
	}
	if cn.Spec.Services.Dolibarr != nil && cn.Spec.Services.Dolibarr.Enabled {
		ingresses = append(ingresses, ingressDef{name: "dolibarr", host: fmt.Sprintf("dolibarr.%s", domain), path: "/", port: 80, tls: "dolibarr-tls"})
	}

	for _, ig := range ingresses {
		if err := r.ensureIngress(ctx, cn, ns, ig.name, ig.host, ig.path, ig.port, ig.tls, issuerName); err != nil {
			log.Error(err, "Failed to create ingress", "name", ig.name)
			return err
		}
	}

	// Glauth LDAPS via IngressRouteTCP (TLS passthrough)
	if err := r.ensureGlauthIngressRouteTCP(ctx, cn, ns, domain); err != nil {
		return err
	}

	return nil
}

func (r *ClientNamespaceReconciler) ensureIngress(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns, name, host, path string, port int, tlsSecret, issuerName string) error {
	ingressName := name
	var ingress networkingv1.Ingress
	err := r.Get(ctx, types.NamespacedName{Name: ingressName, Namespace: ns}, &ingress)
	if err == nil {
		return nil
	}
	if !errors.IsNotFound(err) {
		return err
	}

	annotations := map[string]string{
		"traefik.ingress.kubernetes.io/router.entrypoints": "websecure",
	}
	if issuerName != "" {
		annotations["cert-manager.io/cluster-issuer"] = issuerName
	}

	ingress = networkingv1.Ingress{
		ObjectMeta: metav1.ObjectMeta{
			Name:      ingressName,
			Namespace: ns,
			Labels:    clientLabels(cn),
			Annotations: annotations,
		},
		Spec: networkingv1.IngressSpec{
			IngressClassName: ptrString("traefik"),
			TLS: []networkingv1.IngressTLS{
				{
					Hosts:      []string{host},
					SecretName: tlsSecret,
				},
			},
			Rules: []networkingv1.IngressRule{
				{
					Host: host,
					IngressRuleValue: networkingv1.IngressRuleValue{
						HTTP: &networkingv1.HTTPIngressRuleValue{
							Paths: []networkingv1.HTTPIngressPath{
								{
									Path:     path,
									PathType: ptrPathType(networkingv1.PathTypePrefix),
									Backend: networkingv1.IngressBackend{
										Service: &networkingv1.IngressServiceBackend{
											Name: name,
											Port: networkingv1.ServiceBackendPort{
												Number: int32(port),
											},
										},
									},
								},
							},
						},
					},
				},
			},
		},
	}

	return r.Create(ctx, &ingress)
}

// ensureGlauthIngressRouteTCP creates a Traefik IngressRouteTCP for LDAPS passthrough.
func (r *ClientNamespaceReconciler) ensureGlauthIngressRouteTCP(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns, domain string) error {
	irtName := "glauth-ldaps"
	var existing corev1.Secret
	err := r.Get(ctx, types.NamespacedName{Name: irtName, Namespace: ns}, &existing)
	if err == nil {
		return nil
	}

	// Create IngressRouteTCP via unstructured object
	irt := &unstructured.Unstructured{
		Object: map[string]interface{}{
			"apiVersion": "traefik.io/v1alpha1",
			"kind":       "IngressRouteTCP",
			"metadata": map[string]interface{}{
				"name":      irtName,
				"namespace": ns,
				"labels":    clientLabels(cn),
			},
			"spec": map[string]interface{}{
				"entryPoints": []interface{}{"ldaps"},
				"routes": []interface{}{
					map[string]interface{}{
						"match": fmt.Sprintf("HostSNI(`glauth.%s`)", domain),
						"services": []interface{}{
							map[string]interface{}{
								"name": "glauth",
								"port": 636,
							},
						},
					},
				},
				"tls": map[string]interface{}{
					"passthrough": true,
				},
			},
		},
	}

	return r.Create(ctx, irt)
}

// ─── NETWORK POLICIES ──────────────────────────────────────────────────────────

func (r *ClientNamespaceReconciler) ensureNetworkPolicies(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns string) error {
	// Allow all egress (internet + inter-services)
	if err := r.ensureNetworkPolicyAllowAll(ctx, cn, ns, "allow-all-egress", networkingv1.PolicyTypeEgress); err != nil {
		return err
	}

	// Allow all ingress (from internet)
	if err := r.ensureNetworkPolicyAllowAll(ctx, cn, ns, "allow-all-ingress", networkingv1.PolicyTypeIngress); err != nil {
		return err
	}

	return nil
}

func (r *ClientNamespaceReconciler) ensureNetworkPolicyAllowAll(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns, name string, policyType networkingv1.PolicyType) error {
	npName := fmt.Sprintf("ninekube-%s", name)
	var np networkingv1.NetworkPolicy
	err := r.Get(ctx, types.NamespacedName{Name: npName, Namespace: ns}, &np)
	if err == nil {
		return nil
	}
	if !errors.IsNotFound(err) {
		return err
	}

	np = networkingv1.NetworkPolicy{
		ObjectMeta: metav1.ObjectMeta{
			Name:      npName,
			Namespace: ns,
			Labels:    clientLabels(cn),
		},
		Spec: networkingv1.NetworkPolicySpec{
			PodSelector: metav1.LabelSelector{},
			PolicyTypes: []networkingv1.PolicyType{policyType},
		},
	}

	return r.Create(ctx, &np)
}

// ─── HELPERS ───────────────────────────────────────────────────────────────────

func ptrString(s string) *string {
	return &s
}

func ptrPathType(t networkingv1.PathType) *networkingv1.PathType {
	return &t
}
