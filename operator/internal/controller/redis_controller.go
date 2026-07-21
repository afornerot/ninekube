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

type RedisReconciler struct {
	client.Client
}

func (r *RedisReconciler) Reconcile(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace) error {
	log := log.FromContext(ctx)

	if cn.Spec.Services == nil || cn.Spec.Services.Redis == nil || !cn.Spec.Services.Redis.Enabled {
		return nil
	}

	ns := cn.Status.Namespace
	if ns == "" {
		return fmt.Errorf("namespace not yet provisioned")
	}

	if err := r.ensureDeployment(ctx, cn, ns); err != nil {
		return err
	}
	if err := r.ensureService(ctx, cn, ns); err != nil {
		return err
	}

	log.Info("Redis provisioned", "namespace", ns)
	return nil
}

func (r *RedisReconciler) Cleanup(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace) error {
	return nil
}

func (r *RedisReconciler) ensureDeployment(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns string) error {
	deployName := "redis"
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
				"app.kubernetes.io/name":       "redis",
				"app.kubernetes.io/part-of":    "ninekube",
				"app.kubernetes.io/managed-by": "ninekube-operator",
				"ninekube.io/client":           cn.Name,
			},
		},
		Spec: appsv1.DeploymentSpec{
			Replicas: &replicas,
			Selector: &metav1.LabelSelector{
				MatchLabels: map[string]string{"app.kubernetes.io/name": "redis"},
			},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
		Labels: map[string]string{
					"app.kubernetes.io/name":       "redis",
					"app.kubernetes.io/part-of":    "ninekube",
					"app.kubernetes.io/managed-by": "ninekube-operator",
					"ninekube.io/client":           cn.Name,
				},
				},
				Spec: corev1.PodSpec{
					Containers: []corev1.Container{
						{
							Name:  "redis",
							Image: "redis:7-alpine",
							Ports: []corev1.ContainerPort{
								{Name: "redis", ContainerPort: 6379},
							},
							ReadinessProbe: &corev1.Probe{
								ProbeHandler: corev1.ProbeHandler{
									Exec: &corev1.ExecAction{Command: []string{"redis-cli", "ping"}},
								},
								InitialDelaySeconds: 5,
								PeriodSeconds:       5,
							},
							Resources: corev1.ResourceRequirements{
								Requests: corev1.ResourceList{
									corev1.ResourceCPU:    resource.MustParse("50m"),
									corev1.ResourceMemory: resource.MustParse("64Mi"),
								},
								Limits: corev1.ResourceList{
									corev1.ResourceCPU:    resource.MustParse("200m"),
									corev1.ResourceMemory: resource.MustParse("128Mi"),
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

func (r *RedisReconciler) ensureService(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns string) error {
	svcName := "redis"
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
				"app.kubernetes.io/name":       "redis",
				"app.kubernetes.io/part-of":    "ninekube",
				"app.kubernetes.io/managed-by": "ninekube-operator",
				"ninekube.io/client":           cn.Name,
			},
		},
		Spec: corev1.ServiceSpec{
			Selector: map[string]string{"app.kubernetes.io/name": "redis"},
			Ports: []corev1.ServicePort{
				{Name: "redis", Port: 6379, TargetPort: intstr.FromString("redis")},
			},
		},
	}

	return r.Create(ctx, &svc)
}
