// Copyright (c) 2026 Buildkite Pty Ltd
// SPDX-License-Identifier: MIT

package v1alpha1

import (
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

// CacheStoreConditionReady is the condition type reporting whether Garage and
// its bucket lifecycle configuration are available.
const CacheStoreConditionReady = "Ready"

// CacheStoreRPCSecretReference selects Garage's cluster RPC secret.
type CacheStoreRPCSecretReference struct {
	// name is the name of an immutable Secret in the CacheStore's namespace.
	// +kubebuilder:validation:MinLength=1
	// +required
	Name string `json:"name"`

	// key is the key in the Secret containing a 64-character hexadecimal value.
	// +kubebuilder:validation:MinLength=1
	// +required
	Key string `json:"key"`
}

// CacheStoreCredentialsSecretReference selects the S3 credentials Garage and
// cache clients share.
type CacheStoreCredentialsSecretReference struct {
	// name is the name of an immutable Secret in the CacheStore's namespace.
	// +kubebuilder:validation:MinLength=1
	// +required
	Name string `json:"name"`

	// accessKeyIDKey is the key containing the S3 access-key ID.
	// +kubebuilder:validation:MinLength=1
	// +required
	AccessKeyIDKey string `json:"accessKeyIDKey"`

	// secretAccessKeyKey is the key containing the S3 secret access key.
	// +kubebuilder:validation:MinLength=1
	// +required
	SecretAccessKeyKey string `json:"secretAccessKeyKey"`
}

// CacheStoreStorage configures Garage's persistent volume.
// +kubebuilder:validation:XValidation:rule="self == oldSelf",message="storage is immutable"
type CacheStoreStorage struct {
	// size is the requested capacity of the ReadWriteOnce persistent volume.
	// +kubebuilder:validation:XValidation:rule="quantity(self).isGreaterThan(quantity('0'))",message="size must be greater than zero"
	// +required
	Size resource.Quantity `json:"size"`

	// storageClassName selects the StorageClass for the persistent volume claim.
	// When omitted, the cluster's default StorageClass is used.
	// +optional
	StorageClassName *string `json:"storageClassName,omitempty"`
}

// CacheStoreSpec defines the desired state of CacheStore
type CacheStoreSpec struct {
	// image is the Garage container image.
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:default="dxflrs/garage:v2.3.0"
	// +optional
	Image string `json:"image,omitempty"`

	// bucket is the S3 bucket used for Buildkite cache objects.
	// +kubebuilder:default="buildkite-cache"
	// +kubebuilder:validation:MinLength=3
	// +kubebuilder:validation:MaxLength=63
	// +kubebuilder:validation:Pattern=`^[a-z0-9][a-z0-9.-]*[a-z0-9]$`
	// +kubebuilder:validation:XValidation:rule="!self.contains('..')",message="bucket must not contain adjacent periods"
	// +kubebuilder:validation:XValidation:rule="!self.matches('^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$')",message="bucket must not be formatted as an IP address"
	// +kubebuilder:validation:XValidation:rule="!self.startsWith('xn--') && !self.startsWith('sthree-') && !self.startsWith('amzn_s3_demo_')",message="bucket uses a reserved prefix"
	// +kubebuilder:validation:XValidation:rule="!self.endsWith('-s3alias') && !self.endsWith('--ol-s3') && !self.endsWith('.mrap') && !self.endsWith('--x-s3') && !self.endsWith('--table-s3')",message="bucket uses a reserved suffix"
	// +kubebuilder:validation:XValidation:rule="self == oldSelf",message="bucket is immutable"
	// +optional
	Bucket string `json:"bucket,omitempty"`

	// rpcSecretRef selects Garage's RPC secret.
	// +kubebuilder:validation:XValidation:rule="self == oldSelf",message="rpcSecretRef is immutable"
	// +required
	RPCSecretRef CacheStoreRPCSecretReference `json:"rpcSecretRef"`

	// credentialsSecretRef selects Garage's S3 credentials.
	// +kubebuilder:validation:XValidation:rule="self == oldSelf",message="credentialsSecretRef is immutable"
	// +required
	CredentialsSecretRef CacheStoreCredentialsSecretReference `json:"credentialsSecretRef"`

	// storage configures Garage's persistent volume.
	// +required
	Storage CacheStoreStorage `json:"storage"`

	// retentionDays is the number of day boundaries after which Garage expires
	// cache objects. Restoring an object refreshes its modification time.
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:default=2
	// +optional
	RetentionDays int32 `json:"retentionDays,omitempty"`

	// resources are the compute resources for the Garage container.
	// +optional
	// +kubebuilder:validation:XValidation:rule="!has(self.claims)",message="resources.claims is not supported"
	Resources corev1.ResourceRequirements `json:"resources,omitzero"`

	// lifecycleImage is the AWS CLI image used to apply the bucket lifecycle rule.
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:default="public.ecr.aws/aws-cli/aws-cli:2.27.41"
	// +optional
	LifecycleImage string `json:"lifecycleImage,omitempty"`
}

// CacheStoreStatus defines the observed state of CacheStore.
type CacheStoreStatus struct {
	// conditions represent the current state of the CacheStore resource.
	//
	// Condition types used by this controller:
	// - "Ready": Garage is available and its lifecycle rule is configured
	//
	// The status of each condition is one of True, False, or Unknown.
	// +listType=map
	// +listMapKey=type
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`

	// observedGeneration is the .metadata.generation this status was computed from.
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Bucket",type=string,JSONPath=`.spec.bucket`
// +kubebuilder:printcolumn:name="Ready",type=string,JSONPath=`.status.conditions[?(@.type=='Ready')].status`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`
// +kubebuilder:validation:XValidation:rule="size(self.metadata.name) <= 63 && self.metadata.name.matches('^[a-z]([-a-z0-9]*[a-z0-9])?$')",message="name must be a valid Service name no more than 63 characters"

// CacheStore is the Schema for the cachestores API
type CacheStore struct {
	metav1.TypeMeta `json:",inline"`

	// metadata is a standard object metadata
	// +optional
	metav1.ObjectMeta `json:"metadata,omitzero"`

	// spec defines the desired state of CacheStore
	// +required
	Spec CacheStoreSpec `json:"spec"`

	// status defines the observed state of CacheStore
	// +optional
	Status CacheStoreStatus `json:"status,omitzero"`
}

// +kubebuilder:object:root=true

// CacheStoreList contains a list of CacheStore
type CacheStoreList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitzero"`
	Items           []CacheStore `json:"items"`
}

func init() {
	SchemeBuilder.Register(func(s *runtime.Scheme) error {
		s.AddKnownTypes(SchemeGroupVersion, &CacheStore{}, &CacheStoreList{})
		return nil
	})
}
