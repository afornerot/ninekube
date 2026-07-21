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
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"math/big"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/intstr"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	provisioningv1alpha1 "github.com/ninekube/operator/api/v1alpha1"
)

type DexReconciler struct {
	client.Client
}

func (r *DexReconciler) Reconcile(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace) error {
	log := log.FromContext(ctx)

	if cn.Spec.Services == nil || cn.Spec.Services.Dex == nil || !cn.Spec.Services.Dex.Enabled {
		return nil
	}

	ns := cn.Status.Namespace
	if ns == "" {
		return fmt.Errorf("namespace not yet provisioned")
	}

	if err := r.ensureConfigSecret(ctx, cn, ns); err != nil {
		return err
	}
	if err := r.ensureTLSSecret(ctx, cn, ns); err != nil {
		return err
	}
	if err := r.ensureDeployment(ctx, cn, ns); err != nil {
		return err
	}
	if err := r.ensureService(ctx, cn, ns); err != nil {
		return err
	}

	log.Info("Dex provisioned", "namespace", ns)
	return nil
}

func (r *DexReconciler) Cleanup(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace) error {
	return nil
}

func (r *DexReconciler) ensureConfigSecret(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns string) error {
	secretName := "dex-config"
	var secret corev1.Secret
	err := r.Get(ctx, types.NamespacedName{Name: secretName, Namespace: ns}, &secret)
	if err == nil {
		return nil
	}
	if !errors.IsNotFound(err) {
		return err
	}

	domain := cn.Spec.Domain

	// Read admin password from admin-credentials
	adminPass := "changeme"
	var adminSecret corev1.Secret
	if err := r.Get(ctx, types.NamespacedName{Name: "admin-credentials", Namespace: ns}, &adminSecret); err == nil {
		if pass, ok := adminSecret.Data["password"]; ok && len(pass) > 0 {
			adminPass = string(pass)
		}
	}

	// Read app-secret from ninegate-secret for OIDC client secret
	ninegateClientSecret := "changeme"
	var ngSecret corev1.Secret
	if err := r.Get(ctx, types.NamespacedName{Name: "ninegate-secret", Namespace: ns}, &ngSecret); err == nil {
		if sec, ok := ngSecret.Data["app-secret"]; ok && len(sec) > 0 {
			ninegateClientSecret = string(sec)
		}
	}

	ldapBaseDN := replaceDotsWithDC(domain)

	dexConfig := fmt.Sprintf(`issuer: https://dex.%s

storage:
  type: sqlite3
  config:
    file: /var/dex/dex.db

web:
  https: 0.0.0.0:5556
  tlsCert: /etc/dex/tls/tls.crt
  tlsKey: /etc/dex/tls/tls.key

oauth2:
  responseTypes: ["code", "token", "id_token"]
  skipApprovalScreen: true
  alwaysShowLoginScreen: false
  passwordConnector: local

expiry:
  deviceRequests: "5m"
  idTokens: "24h"
  authRequests: "24h"

signer:
  type: local
  config:
    keysRotationPeriod: "6h"
    algorithm: RS256

enablePasswordDB: false

connectors:
  - type: ldap
    name: LDAP
    id: ldap
    config:
      host: glauth.%s:3893
      insecureNoSSL: true
      insecureBindNoSSL: true
      bindDN: "cn=admin,ou=all,%s"
      bindPW: "%s"
      userSearch:
        baseDN: "ou=users,%s"
        filter: "(objectClass=posixAccount)"
        username: cn
        idAttr: cn
        emailAttr: mail
        nameAttr: cn
      groupSearch:
        baseDN: "ou=groups,%s"
        filter: "(objectClass=groupOfNames)"
        userMatchers:
          - userAttr: DN
            groupAttr: member
        nameAttr: cn

staticClients:
  - id: ninegate
    secret: "%s"
    name: Ninegate
    redirectURIs:
      - "https://ninegate.%s/callback"
  - id: nextcloud
    secret: "changeme"
    name: Nextcloud
    redirectURIs:
      - "https://nextcloud.%s/index.php/login/via oidc_login/"
  - id: tinyfilemanager
    secret: "changeme"
    name: Tiny File Manager
    redirectURIs:
      - "https://files.%s/oauth2/callback"
`, domain, domain, ldapBaseDN, adminPass, ldapBaseDN, ldapBaseDN, ninegateClientSecret, domain, domain, domain)

	secret = corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      secretName,
			Namespace: ns,
			Labels: map[string]string{
				"app.kubernetes.io/name":       "dex",
				"app.kubernetes.io/part-of":    "ninekube",
				"app.kubernetes.io/managed-by": "ninekube-operator",
				"ninekube.io/client":           cn.Name,
			},
		},
		StringData: map[string]string{
			"config.yaml": dexConfig,
		},
	}

	return r.Create(ctx, &secret)
}

func (r *DexReconciler) ensureTLSSecret(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns string) error {
	secretName := "dex-tls"
	var secret corev1.Secret
	err := r.Get(ctx, types.NamespacedName{Name: secretName, Namespace: ns}, &secret)
	if err == nil {
		return nil
	}
	if !errors.IsNotFound(err) {
		return err
	}

	certPEM, keyPEM, err := generateRSASelfSignedCert(fmt.Sprintf("dex.%s", cn.Spec.Domain))
	if err != nil {
		return fmt.Errorf("failed to generate dex TLS cert: %w", err)
	}

	secret = corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      secretName,
			Namespace: ns,
			Labels: map[string]string{
				"app.kubernetes.io/name":       "dex",
				"app.kubernetes.io/part-of":    "ninekube",
				"app.kubernetes.io/managed-by": "ninekube-operator",
				"ninekube.io/client":           cn.Name,
			},
		},
		Type: corev1.SecretTypeTLS,
		Data: map[string][]byte{
			corev1.TLSCertKey:       certPEM,
			corev1.TLSPrivateKeyKey: keyPEM,
		},
	}

	return r.Create(ctx, &secret)
}

func (r *DexReconciler) ensureDeployment(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns string) error {
	deployName := "dex"
	var deploy appsv1.Deployment
	err := r.Get(ctx, types.NamespacedName{Name: deployName, Namespace: ns}, &deploy)
	if err == nil {
		return nil
	}
	if !errors.IsNotFound(err) {
		return err
	}

	var replicas int32 = 1
	deploy = appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      deployName,
			Namespace: ns,
			Labels: map[string]string{
				"app.kubernetes.io/name":       "dex",
				"app.kubernetes.io/part-of":    "ninekube",
				"app.kubernetes.io/managed-by": "ninekube-operator",
				"ninekube.io/client":           cn.Name,
			},
		},
		Spec: appsv1.DeploymentSpec{
			Replicas: &replicas,
			Strategy: appsv1.DeploymentStrategy{
				Type: appsv1.RecreateDeploymentStrategyType,
			},
			Selector: &metav1.LabelSelector{
				MatchLabels: map[string]string{"app.kubernetes.io/name": "dex"},
			},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels: map[string]string{
						"app.kubernetes.io/name":       "dex",
						"app.kubernetes.io/part-of":    "ninekube",
						"app.kubernetes.io/managed-by": "ninekube-operator",
						"ninekube.io/client":           cn.Name,
					},
				},
				Spec: corev1.PodSpec{
					Containers: []corev1.Container{
						{
							Name:  "dex",
							Image: "ghcr.io/dexidp/dex:v2.41.1",
							Command: []string{
								"dex",
								"serve",
								"/etc/dex/config.yaml",
							},
							Ports: []corev1.ContainerPort{
								{Name: "https", ContainerPort: 5556},
								{Name: "grpc", ContainerPort: 5557},
							},
							VolumeMounts: []corev1.VolumeMount{
								{Name: "config", MountPath: "/etc/dex/config.yaml", SubPath: "config.yaml", ReadOnly: true},
								{Name: "tls", MountPath: "/etc/dex/tls", ReadOnly: true},
								{Name: "data", MountPath: "/var/dex"},
							},
							ReadinessProbe: &corev1.Probe{
								ProbeHandler: corev1.ProbeHandler{
									HTTPGet: &corev1.HTTPGetAction{
										Path:   "/healthz",
										Port:   intstr.FromString("https"),
										Scheme: corev1.URISchemeHTTPS,
									},
								},
								InitialDelaySeconds: 5,
								PeriodSeconds:       10,
							},
							LivenessProbe: &corev1.Probe{
								ProbeHandler: corev1.ProbeHandler{
									HTTPGet: &corev1.HTTPGetAction{
										Path:   "/healthz",
										Port:   intstr.FromString("https"),
										Scheme: corev1.URISchemeHTTPS,
									},
								},
								InitialDelaySeconds: 10,
								PeriodSeconds:       30,
							},
							Resources: corev1.ResourceRequirements{
								Requests: corev1.ResourceList{
									corev1.ResourceCPU:    resource.MustParse("50m"),
									corev1.ResourceMemory: resource.MustParse("64Mi"),
								},
								Limits: corev1.ResourceList{
									corev1.ResourceMemory: resource.MustParse("128Mi"),
								},
							},
						},
					},
					Volumes: []corev1.Volume{
						{
							Name: "config",
							VolumeSource: corev1.VolumeSource{
								Secret: &corev1.SecretVolumeSource{
									SecretName: "dex-config",
								},
							},
						},
						{
							Name: "tls",
							VolumeSource: corev1.VolumeSource{
								Secret: &corev1.SecretVolumeSource{
									SecretName: "dex-tls",
								},
							},
						},
						{
							Name: "data",
							VolumeSource: corev1.VolumeSource{
								EmptyDir: &corev1.EmptyDirVolumeSource{},
							},
						},
					},
				},
			},
		},
	}

	return r.Create(ctx, &deploy)
}

func (r *DexReconciler) ensureService(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns string) error {
	svcName := "dex"
	var svc corev1.Service
	err := r.Get(ctx, types.NamespacedName{Name: svcName, Namespace: ns}, &svc)
	if err == nil {
		return nil
	}
	if !errors.IsNotFound(err) {
		return err
	}

	svc = corev1.Service{
		ObjectMeta: metav1.ObjectMeta{
			Name:      svcName,
			Namespace: ns,
			Labels: map[string]string{
				"app.kubernetes.io/name":       "dex",
				"app.kubernetes.io/part-of":    "ninekube",
				"app.kubernetes.io/managed-by": "ninekube-operator",
				"ninekube.io/client":           cn.Name,
			},
		},
		Spec: corev1.ServiceSpec{
			Selector: map[string]string{"app.kubernetes.io/name": "dex"},
			Ports: []corev1.ServicePort{
				{Name: "https", Port: 5556, TargetPort: intstr.FromString("https")},
				{Name: "grpc", Port: 5557, TargetPort: intstr.FromString("grpc")},
			},
		},
	}

	return r.Create(ctx, &svc)
}

func generateRSASelfSignedCert(domain string) ([]byte, []byte, error) {
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, nil, err
	}

	template := x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject: pkix.Name{
			CommonName:   domain,
			Organization: []string{"ninekube"},
		},
		NotBefore:             time.Now(),
		NotAfter:              time.Now().Add(365 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		DNSNames:              []string{domain},
	}

	certDER, err := x509.CreateCertificate(rand.Reader, &template, &template, &priv.PublicKey, priv)
	if err != nil {
		return nil, nil, err
	}

	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: certDER})

	privDER, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		return nil, nil, err
	}
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: privDER})

	return certPEM, keyPEM, nil
}
