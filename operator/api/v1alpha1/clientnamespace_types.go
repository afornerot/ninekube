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

package v1alpha1

import (
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

// ─── PLAN ──────────────────────────────────────────────────────────────────────

// ClientPlan defines the resource sizing for a client namespace.
// +kubebuilder:validation:Enum=starter;standard;premium
type ClientPlan string

const (
	PlanStarter  ClientPlan = "starter"
	PlanStandard ClientPlan = "standard"
	PlanPremium  ClientPlan = "premium"
)

// ─── CERTIFICATE ───────────────────────────────────────────────────────────────

// CertType defines the certificate strategy for a client namespace.
// +kubebuilder:validation:Enum=selfsigned;letsencrypt;secret
type CertType string

const (
	CertSelfSigned    CertType = "selfsigned"
	CertLetsEncrypt   CertType = "letsencrypt"
	CertSecretRef     CertType = "secret"
)

// CertConfig defines the TLS certificate configuration for a client.
type CertConfig struct {
	// type defines how certificates are provisioned.
	// - selfsigned: operator generates a self-signed CA + wildcard cert
	// - letsencrypt: operator creates a cert-manager Certificate with Let's Encrypt
	// - secret: operator uses a user-provided TLS Secret
	// +kubebuilder:default="selfsigned"
	Type CertType `json:"type"`

	// secretName is the name of the TLS Secret to use when type is "secret".
	// The Secret must contain keys "tls.crt", "tls.key", and optionally "ca.crt".
	// +optional
	SecretName string `json:"secretName,omitempty"`

	// issuerRef is the cert-manager ClusterIssuer name when type is "letsencrypt".
	// +optional
	IssuerRef string `json:"issuerRef,omitempty"`
}

// ─── ADMIN ─────────────────────────────────────────────────────────────────────

// AdminConfig defines the admin user configuration for a client namespace.
type AdminConfig struct {
	// email is the admin email address (required for OIDC, password reset, etc.).
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:Format=email
	Email string `json:"email"`

	// passwordSecretRef references a Secret containing the admin password.
	// The Secret must contain a key "password".
	// If not set, the operator auto-generates a random password and stores it
	// in a Secret named "{clientName}-admin-credentials" in the client namespace.
	// +optional
	PasswordSecretRef *corev1.SecretKeySelector `json:"passwordSecretRef,omitempty"`

	// username is the admin username. Defaults to "admin".
	// +optional
	// +kubebuilder:default="admin"
	// +kubebuilder:validation:MinLength=1
	Username string `json:"username,omitempty"`
}

// ─── STORAGE ───────────────────────────────────────────────────────────────────

// StorageConfig defines the storage configuration for a client namespace.
type StorageConfig struct {
	// rustfsBucketPrefix is the prefix for RustFS (S3) bucket names.
	// Buckets will be named: {prefix}-{service} (e.g. "acme-nextcloud-data").
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:validation:Pattern="^[a-z0-9][a-z0-9-]*[a-z0-9]$"
	RustFSBucketPrefix string `json:"rustfsBucketPrefix"`

	// storageClass is the StorageClass to use for PVCs (PostgreSQL, RustFS).
	// Defaults to "longhorn" if not set.
	// +optional
	// +kubebuilder:default="longhorn"
	StorageClass *string `json:"storageClass,omitempty"`

	// pvcSize is the default PVC size for stateful services.
	// +optional
	// +kubebuilder:default="10Gi"
	PVCSize *resource.Quantity `json:"pvcSize,omitempty"`

	// rustfsRootPassword overrides the auto-generated RustFS root password.
	// If not set, a random password is generated and stored in "{clientName}-rustfs-secret".
	// +optional
	RustFSRootPassword string `json:"rustfsRootPassword,omitempty"`

	// postgresRootPassword overrides the auto-generated PostgreSQL root password.
	// If not set, a random password is generated and stored in "{clientName}-postgres-secret".
	// +optional
	PostgresRootPassword string `json:"postgresRootPassword,omitempty"`
}

// ─── SERVICES ──────────────────────────────────────────────────────────────────

// PostgreSQLSpec defines the PostgreSQL service configuration.
type PostgreSQLSpec struct {
	// enabled toggles PostgreSQL provisioning for this client.
	// +kubebuilder:default=true
	Enabled bool `json:"enabled"`

	// storageSize overrides the default PVC size for PostgreSQL data.
	// +optional
	StorageSize *resource.Quantity `json:"storageSize,omitempty"`
}

// RedisSpec defines the Redis service configuration.
type RedisSpec struct {
	// enabled toggles Redis provisioning for this client.
	// +kubebuilder:default=true
	Enabled bool `json:"enabled"`
}

// RustFSSpec defines the RustFS (S3-compatible) service configuration.
type RustFSSpec struct {
	// enabled toggles RustFS provisioning for this client.
	// +kubebuilder:default=true
	Enabled bool `json:"enabled"`

	// storageSize overrides the default PVC size for RustFS data.
	// +optional
	StorageSize *resource.Quantity `json:"storageSize,omitempty"`
}

// NinegateSpec defines the Ninegate service configuration.
type NinegateSpec struct {
	// enabled toggles Ninegate provisioning for this client.
	// +kubebuilder:default=true
	Enabled bool `json:"enabled"`
}

// GlauthSpec defines the Glauth (LDAP) service configuration.
type GlauthSpec struct {
	// enabled toggles Glauth provisioning for this client.
	// +kubebuilder:default=true
	Enabled bool `json:"enabled"`
}

// DexSpec defines the Dex (OIDC) service configuration.
type DexSpec struct {
	// enabled toggles Dex provisioning for this client.
	// Dex provides OIDC authentication, backed by Glauth as LDAP connector.
	// +kubebuilder:default=true
	Enabled bool `json:"enabled"`
}

// NextcloudSpec defines the Nextcloud service configuration.
type NextcloudSpec struct {
	// enabled toggles Nextcloud provisioning for this client.
	// +kubebuilder:default=false
	Enabled bool `json:"enabled"`

	// s3PrimaryStorage uses RustFS as primary storage instead of PVC.
	// When true, data is stored in S3 buckets; local emptyDir is used for plugins.
	// +kubebuilder:default=true
	S3PrimaryStorage bool `json:"s3PrimaryStorage,omitempty"`
}

// WordPressSpec defines the WordPress service configuration.
type WordPressSpec struct {
	// enabled toggles WordPress provisioning for this client.
	// +kubebuilder:default=false
	Enabled bool `json:"enabled"`

	// s3PrimaryStorage uses RustFS as primary storage via FUSE or plugin.
	// +kubebuilder:default=true
	S3PrimaryStorage bool `json:"s3PrimaryStorage,omitempty"`
}

// DolibarrSpec defines the Dolibarr service configuration.
type DolibarrSpec struct {
	// enabled toggles Dolibarr provisioning for this client.
	// +kubebuilder:default=false
	Enabled bool `json:"enabled"`

	// s3PrimaryStorage uses RustFS as primary storage.
	// +kubebuilder:default=true
	S3PrimaryStorage bool `json:"s3PrimaryStorage,omitempty"`
}

// ServicesSpec defines which services to provision in the client namespace.
type ServicesSpec struct {
	// postgresql is the PostgreSQL database service (always provisioned if enabled).
	// +optional
	PostgreSQL *PostgreSQLSpec `json:"postgresql,omitempty"`

	// redis is the Redis caching service.
	// +optional
	Redis *RedisSpec `json:"redis,omitempty"`

	// rustfs is the RustFS S3-compatible object storage.
	// +optional
	RustFS *RustFSSpec `json:"rustfs,omitempty"`

	// ninegate is the Ninegate identity/management application.
	// +optional
	Ninegate *NinegateSpec `json:"ninegate,omitempty"`

	// glauth is the Glauth LDAP server.
	// +optional
	Glauth *GlauthSpec `json:"glauth,omitempty"`

	// dex is the Dex OIDC provider (backed by Glauth LDAP).
	// +optional
	Dex *DexSpec `json:"dex,omitempty"`

	// nextcloud is the Nextcloud file sharing service (optional).
	// +optional
	Nextcloud *NextcloudSpec `json:"nextcloud,omitempty"`

	// wordpress is the WordPress CMS (optional).
	// +optional
	WordPress *WordPressSpec `json:"wordpress,omitempty"`

	// dolibarr is the Dolibarr ERP/CRM (optional).
	// +optional
	Dolibarr *DolibarrSpec `json:"dolibarr,omitempty"`
}

// ─── SPEC ──────────────────────────────────────────────────────────────────────

// ClientNamespaceSpec defines the desired state of ClientNamespace.
type ClientNamespaceSpec struct {
	// domain is the base domain for this client (e.g. "acme.ninekube.io").
	// Ingresses will be created as {service}.{domain}.
	// +kubebuilder:validation:Required
	// +kubebuilder:validation:MinLength=3
	Domain string `json:"domain"`

	// plan determines resource sizing for all services in this namespace.
	// +kubebuilder:validation:Required
	Plan ClientPlan `json:"plan"`

	// cert configures TLS certificates for all services in this namespace.
	// +optional
	Cert *CertConfig `json:"cert,omitempty"`

	// admin configures the admin user for this client namespace.
	// +kubebuilder:validation:Required
	Admin AdminConfig `json:"admin"`

	// storage configures S3 and PVC storage for this client.
	// +optional
	Storage *StorageConfig `json:"storage,omitempty"`

	// services defines which services to provision.
	// +optional
	Services *ServicesSpec `json:"services,omitempty"`
}

// ─── PHASE ─────────────────────────────────────────────────────────────────────

// ClientNamespacePhase describes the current provisioning phase.
// +kubebuilder:validation:Enum=Pending;Provisioning;Ready;Failed
type ClientNamespacePhase string

const (
	PhasePending      ClientNamespacePhase = "Pending"
	PhaseProvisioning ClientNamespacePhase = "Provisioning"
	PhaseReady        ClientNamespacePhase = "Ready"
	PhaseFailed       ClientNamespacePhase = "Failed"
)

// ─── STATUS ────────────────────────────────────────────────────────────────────

// ServiceStatus describes the status of a single service.
type ServiceStatus struct {
	// name is the service name (e.g. "postgresql", "nextcloud").
	// +kubebuilder:validation:Required
	Name string `json:"name"`

	// ready indicates if the service is fully provisioned and healthy.
	Ready bool `json:"ready"`

	// message provides additional context about the service status.
	// +optional
	Message string `json:"message,omitempty"`
}

// ClientNamespaceStatus defines the observed state of ClientNamespace.
type ClientNamespaceStatus struct {
	// phase is the current provisioning phase of the client namespace.
	// +optional
	Phase ClientNamespacePhase `json:"phase,omitempty"`

	// namespace is the name of the Kubernetes namespace created for this client.
	// +optional
	Namespace string `json:"namespace,omitempty"`

	// endpoint is the base URL for accessing this client's services.
	// +optional
	Endpoint string `json:"endpoint,omitempty"`

	// adminSecretName is the name of the Secret containing admin credentials
	// in the client namespace ({clientName}-admin-credentials).
	// +optional
	AdminSecretName string `json:"adminSecretName,omitempty"`

	// certSecretName is the name of the Secret containing TLS certificates
	// in the client namespace.
	// +optional
	CertSecretName string `json:"certSecretName,omitempty"`

	// services reports the status of each provisioned service.
	// +optional
	Services []ServiceStatus `json:"services,omitempty"`

	// conditions represent the latest available observations of the resource's state.
	// +listType=map
	// +listMapKey=type
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// ─── CRD MARKERS ───────────────────────────────────────────────────────────────

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Namespaced,shortName=cn
// +kubebuilder:printcolumn:name="Phase",type=string,JSONPath=".status.phase"
// +kubebuilder:printcolumn:name="Domain",type=string,JSONPath=".spec.domain"
// +kubebuilder:printcolumn:name="Plan",type=string,JSONPath=".spec.plan"
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=".metadata.creationTimestamp"

// ClientNamespace is the Schema for the clientnamespaces API.
// It provisions an isolated namespace with a full ninekube service stack for a client.
type ClientNamespace struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitzero"`

	// spec defines the desired state of ClientNamespace.
	// +required
	Spec ClientNamespaceSpec `json:"spec"`

	// status defines the observed state of ClientNamespace.
	// +optional
	Status ClientNamespaceStatus `json:"status,omitzero"`
}

// +kubebuilder:object:root=true

// ClientNamespaceList contains a list of ClientNamespace.
type ClientNamespaceList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitzero"`
	Items           []ClientNamespace `json:"items"`
}

func init() {
	SchemeBuilder.Register(func(scheme *runtime.Scheme) error {
		scheme.AddKnownTypes(SchemeGroupVersion, &ClientNamespace{}, &ClientNamespaceList{})
		return nil
	})
}
