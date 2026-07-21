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

type PostgreSQLReconciler struct {
	client.Client
}

func (r *PostgreSQLReconciler) Reconcile(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace) error {
	log := log.FromContext(ctx)

	if cn.Spec.Services == nil || cn.Spec.Services.PostgreSQL == nil || !cn.Spec.Services.PostgreSQL.Enabled {
		return nil
	}

	ns := cn.Status.Namespace
	if ns == "" {
		return fmt.Errorf("namespace not yet provisioned")
	}

	// Ensure ConfigMap (init args + init SQL)
	if err := r.ensureConfigMap(ctx, cn, ns); err != nil {
		return err
	}

	// Ensure StatefulSet
	if err := r.ensureStatefulSet(ctx, cn, ns); err != nil {
		return err
	}

	// Ensure Service
	if err := r.ensureService(ctx, cn, ns); err != nil {
		return err
	}

	log.Info("PostgreSQL provisioned", "namespace", ns)
	return nil
}

func (r *PostgreSQLReconciler) Cleanup(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace) error {
	return nil
}

func (r *PostgreSQLReconciler) ensureConfigMap(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns string) error {
	cmName := "postgres-config"
	var cm corev1.ConfigMap
	err := r.Get(ctx, types.NamespacedName{Name: cmName, Namespace: ns}, &cm)
	if err == nil {
		return nil
	}
	if !errors.IsNotFound(err) {
		return err
	}

	initSQL := r.generateInitSQL(cn)

	cm = corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      cmName,
			Namespace: ns,
			Labels: map[string]string{
				"app.kubernetes.io/name":       "postgresql",
				"app.kubernetes.io/part-of":    "ninekube",
				"app.kubernetes.io/managed-by": "ninekube-operator",
				"ninekube.io/client":           cn.Name,
			},
		},
		Data: map[string]string{
			"POSTGRES_INITDB_ARGS": "--auth-host=md5 --auth-local=trust",
			"init.sql":             initSQL,
		},
	}

	return r.Create(ctx, &cm)
}

// generateInitSQL creates SQL statements for all services that need a database.
func (r *PostgreSQLReconciler) generateInitSQL(cn *provisioningv1alpha1.ClientNamespace) string {
	sql := ""

	// ninegate database (tables created by Ninegate on first start)
	sql += "CREATE DATABASE ninegate;\n"

	// Optional services from catalog
	optionalServices := map[string]bool{
		"nextcloud": cn.Spec.Services != nil && cn.Spec.Services.Nextcloud != nil && cn.Spec.Services.Nextcloud.Enabled,
		"wordpress": cn.Spec.Services != nil && cn.Spec.Services.WordPress != nil && cn.Spec.Services.WordPress.Enabled,
		"dolibarr":  cn.Spec.Services != nil && cn.Spec.Services.Dolibarr != nil && cn.Spec.Services.Dolibarr.Enabled,
	}

	for name, enabled := range optionalServices {
		if !enabled {
			continue
		}
		descriptor, ok := ServiceCatalog[name]
		if !ok || descriptor.DatabaseName == "" {
			continue
		}
		sql += fmt.Sprintf("CREATE DATABASE %s;\n", descriptor.DatabaseName)
	}

	return sql
}

func (r *PostgreSQLReconciler) ensureStatefulSet(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns string) error {
	stsName := "postgresql"
	var sts appsv1.StatefulSet
	err := r.Get(ctx, types.NamespacedName{Name: stsName, Namespace: ns}, &sts)
	if err == nil {
		return nil
	}
	if !errors.IsNotFound(err) {
		return err
	}

	var pvcSize resource.Quantity
	if cn.Spec.Services.PostgreSQL.StorageSize != nil {
		pvcSize = *cn.Spec.Services.PostgreSQL.StorageSize
	} else if cn.Spec.Storage != nil && cn.Spec.Storage.PVCSize != nil {
		pvcSize = *cn.Spec.Storage.PVCSize
	} else {
		pvcSize = resource.MustParse("10Gi")
	}

	storageClass := "longhorn"
	if cn.Spec.Storage != nil && cn.Spec.Storage.StorageClass != nil {
		storageClass = *cn.Spec.Storage.StorageClass
	}

	sts = appsv1.StatefulSet{
		ObjectMeta: metav1.ObjectMeta{
			Name:      stsName,
			Namespace: ns,
			Labels: map[string]string{
				"app.kubernetes.io/name":       "postgresql",
				"app.kubernetes.io/part-of":    "ninekube",
				"app.kubernetes.io/managed-by": "ninekube-operator",
				"ninekube.io/client":           cn.Name,
			},
		},
		Spec: appsv1.StatefulSetSpec{
			ServiceName: stsName,
			Replicas:    ptrInt32(1),
			Selector: &metav1.LabelSelector{
				MatchLabels: map[string]string{
					"app.kubernetes.io/name": "postgresql",
				},
			},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels: map[string]string{
						"app.kubernetes.io/name":       "postgresql",
						"app.kubernetes.io/part-of":    "ninekube",
						"app.kubernetes.io/managed-by": "ninekube-operator",
						"ninekube.io/client":           cn.Name,
					},
				},
				Spec: corev1.PodSpec{
					Containers: []corev1.Container{
						{
							Name:  "postgresql",
							Image: "postgres:16",
							Ports: []corev1.ContainerPort{
								{Name: "postgres", ContainerPort: 5432},
							},
							EnvFrom: []corev1.EnvFromSource{
								{
									ConfigMapRef: &corev1.ConfigMapEnvSource{
										LocalObjectReference: corev1.LocalObjectReference{
											Name: "postgres-config",
										},
									},
								},
								{
									SecretRef: &corev1.SecretEnvSource{
										LocalObjectReference: corev1.LocalObjectReference{
											Name: "postgres-secret",
										},
									},
								},
							},
							VolumeMounts: []corev1.VolumeMount{
								{
									Name:      "postgres-data",
									MountPath: "/var/lib/postgresql/data",
									SubPath:   "pgdata",
								},
								{
									Name:      "init-sql",
									MountPath: "/docker-entrypoint-initdb.d",
									ReadOnly:  true,
								},
							},
							ReadinessProbe: &corev1.Probe{
								ProbeHandler: corev1.ProbeHandler{
									Exec: &corev1.ExecAction{
										Command: []string{"pg_isready", "-U", "root", "-d", "ninegate"},
									},
								},
								InitialDelaySeconds: 10,
								PeriodSeconds:       5,
							},
							LivenessProbe: &corev1.Probe{
								ProbeHandler: corev1.ProbeHandler{
									Exec: &corev1.ExecAction{
										Command: []string{"pg_isready", "-U", "root", "-d", "ninegate"},
									},
								},
								InitialDelaySeconds: 30,
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
							Name: "init-sql",
							VolumeSource: corev1.VolumeSource{
								ConfigMap: &corev1.ConfigMapVolumeSource{
									LocalObjectReference: corev1.LocalObjectReference{
										Name: "postgres-config",
									},
								},
							},
						},
					},
				},
			},
			VolumeClaimTemplates: []corev1.PersistentVolumeClaim{
				{
					ObjectMeta: metav1.ObjectMeta{
						Name: "postgres-data",
						Labels: map[string]string{
							"app.kubernetes.io/name":       "postgresql",
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
				},
			},
		},
	}

	return r.Create(ctx, &sts)
}

func (r *PostgreSQLReconciler) ensureService(ctx context.Context, cn *provisioningv1alpha1.ClientNamespace, ns string) error {
	svcName := "postgresql"
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
				"app.kubernetes.io/name":       "postgresql",
				"app.kubernetes.io/part-of":    "ninekube",
				"app.kubernetes.io/managed-by": "ninekube-operator",
				"ninekube.io/client":           cn.Name,
			},
		},
		Spec: corev1.ServiceSpec{
			Selector: map[string]string{
				"app.kubernetes.io/name": "postgresql",
			},
			Ports: []corev1.ServicePort{
				{
					Name:       "postgres",
					Port:       5432,
					TargetPort: intstr.FromString("postgres"),
				},
			},
		},
	}

	return r.Create(ctx, &svc)
}

func ptrInt32(i int32) *int32 {
	return &i
}
