// Copyright (c) 2026 Buildkite Pty Ltd
// SPDX-License-Identifier: MIT

package v1alpha1

import (
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

const (
	// RunnerPoolConditionReady is the condition type reporting whether a pool's
	// agents are running and available.
	RunnerPoolConditionReady = "Ready"

	// RunnerPoolConditionCacheStoreReady reports the state of the optional
	// CacheStore used by a pool.
	RunnerPoolConditionCacheStoreReady = "CacheStoreReady"
)

// CacheStoreReference identifies a CacheStore in the RunnerPool's namespace.
type CacheStoreReference struct {
	// name is the name of the CacheStore.
	// +kubebuilder:validation:MinLength=1
	// +required
	Name string `json:"name"`
}

// +kubebuilder:validation:XValidation:rule="self.minIdleRunners <= self.maxRunners",message="minIdleRunners must be less than or equal to maxRunners"

// RunnerPoolSpec defines the desired state of RunnerPool
type RunnerPoolSpec struct {
	// queue is the Buildkite queue that agents in this pool register with.
	// +kubebuilder:validation:MinLength=1
	// +required
	Queue string `json:"queue"`

	// maxRunners is the maximum number of agents that may run in this pool.
	// +kubebuilder:validation:Minimum=1
	// +required
	MaxRunners int32 `json:"maxRunners"`

	// minIdleRunners is the number of idle agents to keep ready for work. Setting
	// it to zero allows the pool to scale to zero, where it remains until
	// minIdleRunners is increased because the operator does not observe
	// Buildkite queue depth.
	// +kubebuilder:default=1
	// +kubebuilder:validation:Minimum=0
	// +optional
	MinIdleRunners *int32 `json:"minIdleRunners,omitempty"`

	// idleTimeoutSeconds is how long an agent must be observed idle before it
	// may be removed as surplus capacity.
	// +kubebuilder:default=10
	// +kubebuilder:validation:Minimum=0
	// +optional
	IdleTimeoutSeconds *int32 `json:"idleTimeoutSeconds,omitempty"`

	// terminationGracePeriodSeconds is how long Kubernetes gives an agent to
	// finish a job after receiving SIGTERM before forcibly stopping it.
	// +kubebuilder:default=3600
	// +kubebuilder:validation:Minimum=1
	// +optional
	TerminationGracePeriodSeconds *int64 `json:"terminationGracePeriodSeconds,omitempty"`

	// image is the Buildkite agent container image to run.
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:default="buildkite/agent:3"
	// +optional
	Image string `json:"image,omitempty"`

	// agentTokenSecretRef references the secret key holding the Buildkite agent
	// token that agents in this pool authenticate with.
	// +required
	// +kubebuilder:validation:XValidation:rule="has(self.name) && size(self.name) > 0",message="agentTokenSecretRef.name must not be empty"
	AgentTokenSecretRef corev1.SecretKeySelector `json:"agentTokenSecretRef"`

	// resources are the compute resources for each agent container.
	//
	// resources.claims is not supported: the controller does not model the
	// corresponding pod-level spec.resourceClaims, so a container claim would
	// have nothing to reference and the resulting Pod would be rejected.
	// +optional
	// +kubebuilder:validation:XValidation:rule="!has(self.claims)",message="resources.claims is not supported"
	Resources corev1.ResourceRequirements `json:"resources,omitzero"`

	// cacheStoreRef optionally references a CacheStore in this RunnerPool's
	// namespace. Cache-enabled agents require Buildkite agent 3.128.0 or newer.
	// +optional
	CacheStoreRef *CacheStoreReference `json:"cacheStoreRef,omitempty"`
}

// RunnerPoolStatus defines the observed state of RunnerPool.
type RunnerPoolStatus struct {
	// conditions represent the current state of the RunnerPool resource.
	//
	// Condition types used by this controller:
	// - "Ready": the pool's agents are running and available
	// - "CacheStoreReady": the configured CacheStore is available
	//
	// The status of each condition is one of True, False, or Unknown.
	// +listType=map
	// +listMapKey=type
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`

	// totalRunners is the number of non-terminating agents in this pool.
	// +optional
	TotalRunners int32 `json:"totalRunners,omitempty"`

	// idleRunners is the number of ready agents confirmed idle by their status endpoint.
	// +optional
	IdleRunners int32 `json:"idleRunners,omitempty"`

	// busyRunners is the number of agents confirmed to be running a job.
	// +optional
	BusyRunners int32 `json:"busyRunners,omitempty"`

	// readyRunners is the number of agents in this pool that are ready.
	// +optional
	ReadyRunners int32 `json:"readyRunners,omitempty"`

	// observedGeneration is the .metadata.generation this status was computed from.
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Max",type=integer,JSONPath=`.spec.maxRunners`
// +kubebuilder:printcolumn:name="Idle",type=integer,JSONPath=`.status.idleRunners`
// +kubebuilder:printcolumn:name="Busy",type=integer,JSONPath=`.status.busyRunners`
// +kubebuilder:printcolumn:name="Total",type=integer,JSONPath=`.status.totalRunners`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`
// +kubebuilder:validation:XValidation:rule="size(self.metadata.name) <= 63",message="name must be no more than 63 characters, as it is copied into label values on the pool's Pods"

// RunnerPool is the Schema for the runnerpools API
type RunnerPool struct {
	metav1.TypeMeta `json:",inline"`

	// metadata is a standard object metadata
	// +optional
	metav1.ObjectMeta `json:"metadata,omitzero"`

	// spec defines the desired state of RunnerPool
	// +required
	Spec RunnerPoolSpec `json:"spec"`

	// status defines the observed state of RunnerPool
	// +optional
	Status RunnerPoolStatus `json:"status,omitzero"`
}

// +kubebuilder:object:root=true

// RunnerPoolList contains a list of RunnerPool
type RunnerPoolList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitzero"`
	Items           []RunnerPool `json:"items"`
}

func init() {
	SchemeBuilder.Register(func(s *runtime.Scheme) error {
		s.AddKnownTypes(SchemeGroupVersion, &RunnerPool{}, &RunnerPoolList{})
		return nil
	})
}
