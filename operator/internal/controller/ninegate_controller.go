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

type NinegateReconciler struct {
	client.Client
}

func (r *NinegateReconciler) Reconcile(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace) error {
	log := log.FromContext(ctx)

	if cn.Spec.Services == nil || cn.Spec.Services.Ninegate == nil || !cn.Spec.Services.Ninegate.Enabled {
		return nil
	}

	ns := cn.Status.Namespace
	if ns == "" {
		return fmt.Errorf("namespace not yet provisioned")
	}

	// Ensure PVCs
	if err := r.ensurePVCs(ctx, cn, ns); err != nil {
		return err
	}

	if err := r.ensureDeployment(ctx, cn, ns); err != nil {
		return err
	}
	if err := r.ensureService(ctx, cn, ns); err != nil {
		return err
	}

	log.Info("Ninegate provisioned", "namespace", ns)
	return nil
}

func (r *NinegateReconciler) Cleanup(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace) error {
	return nil
}

func (r *NinegateReconciler) ensurePVCs(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns string) error {
	for _, pvcName := range []string{"ninegate-uploads", "ninegate-public-uploads"} {
		var pvc corev1.PersistentVolumeClaim
		err := r.Get(ctx, types.NamespacedName{Name: pvcName, Namespace: ns}, &pvc)
		if err == nil {
			continue
		}
		if !errors.IsNotFound(err) {
			return err
		}

		storageClass := "longhorn"
		pvcSize := resource.MustParse("10Gi")

		pvc = corev1.PersistentVolumeClaim{
			ObjectMeta: metav1.ObjectMeta{
				Name:      pvcName,
				Namespace: ns,
				Labels: map[string]string{
					"app.kubernetes.io/name":       "ninegate",
					"app.kubernetes.io/part-of":    "ninekube",
					"app.kubernetes.io/managed-by": "ninekube-operator",
					"ninekube.io/client":           cn.Name,
				},
			},
			Spec: corev1.PersistentVolumeClaimSpec{
				AccessModes:      []corev1.PersistentVolumeAccessMode{corev1.ReadWriteOnce},
				StorageClassName: &storageClass,
				Resources: corev1.VolumeResourceRequirements{
					Requests: corev1.ResourceList{
						corev1.ResourceStorage: pvcSize,
					},
				},
			},
		}

		if err := r.Create(ctx, &pvc); err != nil {
			return err
		}
	}
	return nil
}

func (r *NinegateReconciler) ensureDeployment(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns string) error {
	deployName := "ninegate"
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
				"app.kubernetes.io/name":       "ninegate",
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
				MatchLabels: map[string]string{"app.kubernetes.io/name": "ninegate"},
			},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels: map[string]string{
						"app.kubernetes.io/name":       "ninegate",
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
					},
					Containers: []corev1.Container{
						{
							Name:  "ninegate",
							Image: "ghcr.io/afornerot/ninegate:main",
							Ports: []corev1.ContainerPort{
								{Name: "http", ContainerPort: 80},
							},
							Env: []corev1.EnvVar{
								{Name: "APP_ENV", Value: "prod"},
								{Name: "APP_SECRET", ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{LocalObjectReference: corev1.LocalObjectReference{Name: "ninegate-secret"}, Key: "app-secret"}}},
								{Name: "DATABASE_URL", ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{LocalObjectReference: corev1.LocalObjectReference{Name: "ninegate-secret"}, Key: "database-url"}}},
								{Name: "DEFAULT_URI", ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{LocalObjectReference: corev1.LocalObjectReference{Name: "ninegate-secret"}, Key: "default-uri"}}},
								{Name: "APP_MODEAUTH", Value: "OIDC"},
								{Name: "APP_MASTERIDENTITY", Value: "SQL"},
								{Name: "LDAP_BASE", ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{LocalObjectReference: corev1.LocalObjectReference{Name: "ninegate-secret"}, Key: "ldap-base"}}},
								{Name: "OIDC_ISSUER", ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{LocalObjectReference: corev1.LocalObjectReference{Name: "ninegate-secret"}, Key: "oidc-issuer"}}},
								{Name: "OIDC_CLIENTID", Value: "ninegate"},
								{Name: "OIDC_CLIENTSECRET", ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{LocalObjectReference: corev1.LocalObjectReference{Name: "ninegate-secret"}, Key: "oidc-client-secret"}}},
								{Name: "OIDC_REDIRECTURI", ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{LocalObjectReference: corev1.LocalObjectReference{Name: "ninegate-secret"}, Key: "oidc-redirect-uri"}}},
								{Name: "APP_ADMIN_PASSWORD", ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{LocalObjectReference: corev1.LocalObjectReference{Name: "ninegate-secret"}, Key: "app-admin-password"}}},
								{Name: "OIDC_MAILATTRIBUTE", Value: "email"},
								{Name: "OIDC_USERNAMEATTRIBUTE", Value: "name"},
								{Name: "STORAGE_DSN", ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{LocalObjectReference: corev1.LocalObjectReference{Name: "ninegate-secret"}, Key: "storage-dsn"}}},
								{Name: "STORAGE_S3", Value: "1"},
								{Name: "S3_ENDPOINT", ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{LocalObjectReference: corev1.LocalObjectReference{Name: "ninegate-secret"}, Key: "s3-endpoint"}}},
								{Name: "S3_BUCKET", ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{LocalObjectReference: corev1.LocalObjectReference{Name: "ninegate-secret"}, Key: "s3-bucket"}}},
								{Name: "S3_ACCESS_KEY", ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{LocalObjectReference: corev1.LocalObjectReference{Name: "ninegate-secret"}, Key: "s3-access-key"}}},
								{Name: "S3_SECRET_KEY", ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{LocalObjectReference: corev1.LocalObjectReference{Name: "ninegate-secret"}, Key: "s3-secret-key"}}},
								{Name: "S3_REGION", ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{LocalObjectReference: corev1.LocalObjectReference{Name: "ninegate-secret"}, Key: "s3-region"}}},
							},
							VolumeMounts: []corev1.VolumeMount{
								{Name: "uploads", MountPath: "/app/uploads"},
								{Name: "public-uploads", MountPath: "/app/public/uploads"},
								{Name: "glauth-config", MountPath: "/app/volume/glauth", ReadOnly: true},
							},
							ReadinessProbe: &corev1.Probe{
								ProbeHandler: corev1.ProbeHandler{
									HTTPGet: &corev1.HTTPGetAction{Path: "/", Port: intstr.FromString("http")},
								},
								InitialDelaySeconds: 30,
								PeriodSeconds:       10,
							},
							LivenessProbe: &corev1.Probe{
								ProbeHandler: corev1.ProbeHandler{
									HTTPGet: &corev1.HTTPGetAction{Path: "/", Port: intstr.FromString("http")},
								},
								InitialDelaySeconds: 60,
								PeriodSeconds:       30,
							},
							Resources: corev1.ResourceRequirements{
								Requests: corev1.ResourceList{
									corev1.ResourceCPU:    resource.MustParse("100m"),
									corev1.ResourceMemory: resource.MustParse("256Mi"),
								},
							},
						},
					},
					Volumes: []corev1.Volume{
						{
							Name: "uploads",
							VolumeSource: corev1.VolumeSource{
								PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{ClaimName: "ninegate-uploads"},
							},
						},
						{
							Name: "public-uploads",
							VolumeSource: corev1.VolumeSource{
								PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{ClaimName: "ninegate-public-uploads"},
							},
						},
						{
							Name: "glauth-config",
							VolumeSource: corev1.VolumeSource{
								ConfigMap: &corev1.ConfigMapVolumeSource{
									LocalObjectReference: corev1.LocalObjectReference{Name: "ninegate-glauth-config"},
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

func (r *NinegateReconciler) ensureService(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns string) error {
	svcName := "ninegate"
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
				"app.kubernetes.io/name":       "ninegate",
				"app.kubernetes.io/part-of":    "ninekube",
				"app.kubernetes.io/managed-by": "ninekube-operator",
				"ninekube.io/client":           cn.Name,
			},
		},
		Spec: corev1.ServiceSpec{
			Selector: map[string]string{"app.kubernetes.io/name": "ninegate"},
			Ports: []corev1.ServicePort{
				{Name: "http", Port: 80, TargetPort: intstr.FromString("http")},
			},
		},
	}

	return r.Create(ctx, &svc)
}
