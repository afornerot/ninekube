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

type RustFSReconciler struct {
	client.Client
}

func (r *RustFSReconciler) Reconcile(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace) error {
	log := log.FromContext(ctx)

	if cn.Spec.Services == nil || cn.Spec.Services.RustFS == nil || !cn.Spec.Services.RustFS.Enabled {
		return nil
	}

	ns := cn.Status.Namespace
	if ns == "" {
		return fmt.Errorf("namespace not yet provisioned")
	}

	// Ensure PVC
	if err := r.ensurePVC(ctx, cn, ns); err != nil {
		return err
	}

	// Ensure Deployment
	if err := r.ensureDeployment(ctx, cn, ns); err != nil {
		return err
	}

	// Ensure Service
	if err := r.ensureService(ctx, cn, ns); err != nil {
		return err
	}

	log.Info("RustFS provisioned", "namespace", ns)
	return nil
}

func (r *RustFSReconciler) Cleanup(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace) error {
	return nil
}

func (r *RustFSReconciler) ensurePVC(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns string) error {
	pvcName := "rustfs-data"
	var pvc corev1.PersistentVolumeClaim
	err := r.Get(ctx, types.NamespacedName{Name: pvcName, Namespace: ns}, &pvc)
	if err == nil {
		return nil
	}
	if !errors.IsNotFound(err) {
		return err
	}

	var pvcSize resource.Quantity
	if cn.Spec.Services.RustFS.StorageSize != nil {
		pvcSize = *cn.Spec.Services.RustFS.StorageSize
	} else if cn.Spec.Storage != nil && cn.Spec.Storage.PVCSize != nil {
		pvcSize = *cn.Spec.Storage.PVCSize
	} else {
		pvcSize = resource.MustParse("10Gi")
	}

	storageClass := "longhorn"
	if cn.Spec.Storage != nil && cn.Spec.Storage.StorageClass != nil {
		storageClass = *cn.Spec.Storage.StorageClass
	}

	pvc = corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{
			Name:      pvcName,
			Namespace: ns,
			Labels: map[string]string{
				"app.kubernetes.io/name":       "rustfs",
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

	return r.Create(ctx, &pvc)
}

func (r *RustFSReconciler) ensureDeployment(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns string) error {
	deployName := "rustfs"
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
				"app.kubernetes.io/name":       "rustfs",
				"app.kubernetes.io/part-of":    "ninekube",
				"app.kubernetes.io/managed-by": "ninekube-operator",
				"ninekube.io/client":           cn.Name,
			},
		},
		Spec: appsv1.DeploymentSpec{
			Replicas: &replicas,
			Selector: &metav1.LabelSelector{
				MatchLabels: map[string]string{"app.kubernetes.io/name": "rustfs"},
			},
			Strategy: appsv1.DeploymentStrategy{
				Type: appsv1.RecreateDeploymentStrategyType,
			},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
		Labels: map[string]string{
					"app.kubernetes.io/name":       "rustfs",
					"app.kubernetes.io/part-of":    "ninekube",
					"app.kubernetes.io/managed-by": "ninekube-operator",
					"ninekube.io/client":           cn.Name,
				},
				},
				Spec: corev1.PodSpec{
					Containers: []corev1.Container{
						{
							Name:  "rustfs",
							Image: "rustfs/rustfs:latest",
							Ports: []corev1.ContainerPort{
								{Name: "api", ContainerPort: 9000},
								{Name: "console", ContainerPort: 9001},
							},
							SecurityContext: &corev1.SecurityContext{
								RunAsUser: ptrInt64(0),
							},
							EnvFrom: []corev1.EnvFromSource{
							{
								SecretRef: &corev1.SecretEnvSource{
									LocalObjectReference: corev1.LocalObjectReference{Name: "rustfs-secret"},
								},
							},
						},
						Env: []corev1.EnvVar{
							{Name: "RUSTFS_VOLUMES", Value: "/data"},
						},
							VolumeMounts: []corev1.VolumeMount{
								{Name: "data", MountPath: "/data"},
							},
							ReadinessProbe: &corev1.Probe{
								ProbeHandler: corev1.ProbeHandler{
									HTTPGet: &corev1.HTTPGetAction{Path: "/minio/health/live", Port: intstr.FromInt32(9000)},
								},
								InitialDelaySeconds: 10,
								PeriodSeconds:       10,
							},
							Resources: corev1.ResourceRequirements{
								Requests: corev1.ResourceList{
									corev1.ResourceCPU:    resource.MustParse("100m"),
									corev1.ResourceMemory: resource.MustParse("128Mi"),
								},
								Limits: corev1.ResourceList{
									corev1.ResourceCPU:    resource.MustParse("500m"),
									corev1.ResourceMemory: resource.MustParse("512Mi"),
								},
							},
						},
					},
					Volumes: []corev1.Volume{
						{
							Name: "data",
							VolumeSource: corev1.VolumeSource{
								PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{
									ClaimName: "rustfs-data",
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

func (r *RustFSReconciler) ensureService(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns string) error {
	svcName := "rustfs"
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
				"app.kubernetes.io/name":       "rustfs",
				"app.kubernetes.io/part-of":    "ninekube",
				"app.kubernetes.io/managed-by": "ninekube-operator",
				"ninekube.io/client":           cn.Name,
			},
		},
		Spec: corev1.ServiceSpec{
			Selector: map[string]string{"app.kubernetes.io/name": "rustfs"},
			Ports: []corev1.ServicePort{
				{Name: "api", Port: 9000, TargetPort: intstr.FromInt32(9000)},
				{Name: "console", Port: 9001, TargetPort: intstr.FromInt32(9001)},
			},
		},
	}

	return r.Create(ctx, &svc)
}

func ptrInt64(i int64) *int64 {
	return &i
}
