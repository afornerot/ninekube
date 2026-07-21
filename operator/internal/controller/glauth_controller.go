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
	"fmt"

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

type GlauthReconciler struct {
	client.Client
}

func (r *GlauthReconciler) Reconcile(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace) error {
	log := log.FromContext(ctx)

	if cn.Spec.Services == nil || cn.Spec.Services.Glauth == nil || !cn.Spec.Services.Glauth.Enabled {
		return nil
	}

	ns := cn.Status.Namespace
	if ns == "" {
		return fmt.Errorf("namespace not yet provisioned")
	}

	if err := r.ensureConfigMap(ctx, cn, ns); err != nil {
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

	log.Info("Glauth provisioned", "namespace", ns)
	return nil
}

func (r *GlauthReconciler) Cleanup(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace) error {
	return nil
}

func (r *GlauthReconciler) ensureConfigMap(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns string) error {
	cmName := "ninegate-glauth-config"
	var cm corev1.ConfigMap
	err := r.Get(ctx, types.NamespacedName{Name: cmName, Namespace: ns}, &cm)
	if err == nil {
		return nil
	}
	if !errors.IsNotFound(err) {
		return err
	}

	// Read the actual password from the postgres-secret
	var pgSecret corev1.Secret
	if err := r.Get(ctx, types.NamespacedName{Name: "postgres-secret", Namespace: ns}, &pgSecret); err != nil {
		return fmt.Errorf("postgres-secret not found: %w", err)
	}
	pgPass := string(pgSecret.Data["POSTGRES_PASSWORD"])

	domain := cn.Spec.Domain
	ldapBaseDN := replaceDotsWithDC(domain)

	glauthConfig := fmt.Sprintf(`[backend]
  datastore = "plugin"
  plugin = "/app/postgres.so"
  pluginhandler = "NewPostgresHandler"
  database = "host=postgresql port=5432 user=root password=%s dbname=ninegate sslmode=disable"
  baseDN = "%s"

[ldap]
  enabled = true
  listen = "0.0.0.0:3893"
  tls = false

[ldaps]
  enabled = true
  listen = "0.0.0.0:636"
  tls = true
  cert = "/etc/glauth/tls/tls.crt"
  key = "/etc/glauth/tls/tls.key"

[behaviors]
  IgnoreCapabilities = true
  LimitFailedBinds = true
  NumberOfFailedBinds = 3
  PeriodOfFailedBinds = 10
  BlockFailedBindsFor = 60
  PruneSourceTableEvery = 600
  PruneSourcesOlderThan = 600
`, pgPass, ldapBaseDN)

	cm = corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      cmName,
			Namespace: ns,
			Labels: map[string]string{
				"app.kubernetes.io/name":       "glauth",
				"app.kubernetes.io/part-of":    "ninekube",
				"app.kubernetes.io/managed-by": "ninekube-operator",
				"ninekube.io/client":           cn.Name,
			},
		},
		Data: map[string]string{
			"config.cfg": glauthConfig,
		},
	}

	return r.Create(ctx, &cm)
}

func (r *GlauthReconciler) ensureTLSSecret(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns string) error {
	secretName := "glauth-tls"
	var secret corev1.Secret
	err := r.Get(ctx, types.NamespacedName{Name: secretName, Namespace: ns}, &secret)
	if err == nil {
		return nil
	}
	if !errors.IsNotFound(err) {
		return err
	}

	certPEM, keyPEM, err := generateRSASelfSignedCert(fmt.Sprintf("glauth.%s", cn.Spec.Domain))
	if err != nil {
		return fmt.Errorf("failed to generate glauth TLS cert: %w", err)
	}

	secret = corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name:      secretName,
			Namespace: ns,
			Labels: map[string]string{
				"app.kubernetes.io/name":       "glauth",
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

func (r *GlauthReconciler) ensureDeployment(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns string) error {
	deployName := "glauth"
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
				"app.kubernetes.io/name":       "glauth",
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
				MatchLabels: map[string]string{"app.kubernetes.io/name": "glauth"},
			},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels: map[string]string{
						"app.kubernetes.io/name":       "glauth",
						"app.kubernetes.io/part-of":    "ninekube",
						"app.kubernetes.io/managed-by": "ninekube-operator",
						"ninekube.io/client":           cn.Name,
					},
				},
				Spec: corev1.PodSpec{
					InitContainers: []corev1.Container{
						{
							Name:  "wait-postgres",
							Image: "busybox:1.36",
							Command: []string{"sh", "-c", "until nc -z postgresql 5432; do echo waiting for postgres...; sleep 2; done"},
						},
						{
							Name:  "wait-ninegate",
							Image: "busybox:1.36",
							Command: []string{"sh", "-c", "until wget -q -O- --spider http://ninegate:80/ 2>/dev/null; do echo waiting for ninegate...; sleep 3; done"},
						},
					},
					Containers: []corev1.Container{
						{
							Name:  "glauth",
							Image: "ghcr.io/glauth/glauth-plugins:v2.4.0",
							Ports: []corev1.ContainerPort{
								{Name: "ldap", ContainerPort: 3893},
								{Name: "ldaps", ContainerPort: 636},
							},
							VolumeMounts: []corev1.VolumeMount{
								{Name: "config", MountPath: "/app/config", ReadOnly: true},
								{Name: "tls", MountPath: "/etc/glauth/tls", ReadOnly: true},
							},
							ReadinessProbe: &corev1.Probe{
								ProbeHandler: corev1.ProbeHandler{
									TCPSocket: &corev1.TCPSocketAction{Port: intstr.FromString("ldap")},
								},
								InitialDelaySeconds: 5,
								PeriodSeconds:       10,
							},
							LivenessProbe: &corev1.Probe{
								ProbeHandler: corev1.ProbeHandler{
									TCPSocket: &corev1.TCPSocketAction{Port: intstr.FromString("ldap")},
								},
								InitialDelaySeconds: 10,
								PeriodSeconds:       30,
							},
							Resources: corev1.ResourceRequirements{
								Requests: corev1.ResourceList{
									corev1.ResourceCPU:    resource.MustParse("50m"),
									corev1.ResourceMemory: resource.MustParse("64Mi"),
								},
							},
						},
					},
					Volumes: []corev1.Volume{
						{
							Name: "config",
							VolumeSource: corev1.VolumeSource{
								ConfigMap: &corev1.ConfigMapVolumeSource{
									LocalObjectReference: corev1.LocalObjectReference{Name: "ninegate-glauth-config"},
								},
							},
						},
						{
							Name: "tls",
							VolumeSource: corev1.VolumeSource{
								Secret: &corev1.SecretVolumeSource{
									SecretName: "glauth-tls",
								},
							},
						},
					},
				},
			},
		},
	}

	return r.Create(ctx, &deploy)
}

func (r *GlauthReconciler) ensureService(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns string) error {
	svcName := "glauth"
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
				"app.kubernetes.io/name":       "glauth",
				"app.kubernetes.io/part-of":    "ninekube",
				"app.kubernetes.io/managed-by": "ninekube-operator",
				"ninekube.io/client":           cn.Name,
			},
		},
		Spec: corev1.ServiceSpec{
			Selector: map[string]string{"app.kubernetes.io/name": "glauth"},
			Ports: []corev1.ServicePort{
				{Name: "ldap", Port: 3893, TargetPort: intstr.FromString("ldap")},
				{Name: "ldaps", Port: 636, TargetPort: intstr.FromString("ldaps")},
			},
		},
	}

	return r.Create(ctx, &svc)
}

func replaceDotsWithDC(domain string) string {
	result := ""
	for _, c := range domain {
		if c == '.' {
			result += ",dc="
		} else {
			result += string(c)
		}
	}
	return "dc=" + result
}
