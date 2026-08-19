// Copyright (c) 2026 Buildkite Pty Ltd
// SPDX-License-Identifier: MIT

package v1alpha1

import (
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

// RunnerPoolConditionReady is the condition type reporting whether a pool's
// agents are running and available.
const RunnerPoolConditionReady = "Ready"

// RunnerPoolSpec defines the desired state of RunnerPool
type RunnerPoolSpec struct {
	// queue is the Buildkite queue that agents in this pool register with.
	// +kubebuilder:validation:MinLength=1
	// +required
	Queue string `json:"queue"`

	// replicas is the number of agents to run in this pool.
	// +kubebuilder:validation:Minimum=0
	// +kubebuilder:default=1
	// +optional
	Replicas *int32 `json:"replicas,omitempty"`

	// image is the Buildkite agent container image to run.
	// +kubebuilder:validation:MinLength=1
	// +kubebuilder:default="buildkite/agent:3"
	// +optional
	Image string `json:"image,omitempty"`

	// agentTokenSecretRef references the secret key holding the Buildkite agent
	// token that agents in this pool authenticate with.
	// +required
	AgentTokenSecretRef corev1.SecretKeySelector `json:"agentTokenSecretRef"`

	// resources are the compute resources for each agent container.
	// +optional
	Resources corev1.ResourceRequirements `json:"resources,omitzero"`
}

// RunnerPoolStatus defines the observed state of RunnerPool.
type RunnerPoolStatus struct {
	// conditions represent the current state of the RunnerPool resource.
	//
	// Condition types used by this controller:
	// - "Ready": the pool's agents are running and available
	//
	// The status of each condition is one of True, False, or Unknown.
	// +listType=map
	// +listMapKey=type
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`

	// readyReplicas is the number of agents in this pool that are ready.
	// +optional
	ReadyReplicas int32 `json:"readyReplicas,omitempty"`

	// observedGeneration is the .metadata.generation this status was computed from.
	// +optional
	ObservedGeneration int64 `json:"observedGeneration,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:subresource:scale:specpath=.spec.replicas,statuspath=.status.readyReplicas
// +kubebuilder:printcolumn:name="Queue",type=string,JSONPath=`.spec.queue`
// +kubebuilder:printcolumn:name="Desired",type=integer,JSONPath=`.spec.replicas`
// +kubebuilder:printcolumn:name="Ready",type=integer,JSONPath=`.status.readyReplicas`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`

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
