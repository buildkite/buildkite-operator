// Copyright (c) 2026 Buildkite Pty Ltd
// SPDX-License-Identifier: MIT

package controller

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"net/url"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
	ctrl "sigs.k8s.io/controller-runtime"

	buildkitecomv1alpha1 "github.com/buildkite/buildkite-operator/api/v1alpha1"
)

func (r *RunnerPoolReconciler) agentPod(
	pool *buildkitecomv1alpha1.RunnerPool,
	store *buildkitecomv1alpha1.CacheStore,
	templateHash string,
) (*corev1.Pod, error) {
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			GenerateName: pool.Name + "-agent-",
			Namespace:    pool.Namespace,
			Labels:       poolLabels(pool),
			Annotations: map[string]string{
				podTemplateHashAnnotation: templateHash,
			},
		},
		Spec: desiredAgentPodSpec(pool, store),
	}
	if err := ctrl.SetControllerReference(pool, pod, r.Scheme); err != nil {
		return nil, err
	}
	return pod, nil
}

func desiredAgentPodSpec(
	pool *buildkitecomv1alpha1.RunnerPool,
	store *buildkitecomv1alpha1.CacheStore,
) corev1.PodSpec {
	return corev1.PodSpec{
		TerminationGracePeriodSeconds: desiredTerminationGracePeriodSeconds(pool),
		Containers: []corev1.Container{
			{
				Name:      agentContainerName,
				Image:     desiredImage(pool),
				Env:       agentEnv(pool, store),
				Resources: desiredResources(pool),
				Ports: []corev1.ContainerPort{
					{
						Name:          agentHealthPortName,
						ContainerPort: agentHealthPort,
						Protocol:      corev1.ProtocolTCP,
					},
				},
				ReadinessProbe: &corev1.Probe{
					ProbeHandler: corev1.ProbeHandler{
						HTTPGet: &corev1.HTTPGetAction{
							Path:   "/agent/1",
							Port:   intstr.FromString(agentHealthPortName),
							Scheme: corev1.URISchemeHTTP,
						},
					},
				},
			},
		},
	}
}

func desiredPodTemplateHash(
	pool *buildkitecomv1alpha1.RunnerPool,
	store *buildkitecomv1alpha1.CacheStore,
) (string, error) {
	template, err := json.Marshal(desiredAgentPodSpec(pool, store))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%x", sha256.Sum256(template)), nil
}

// agentEnv is the environment every agent in the pool runs with.
func agentEnv(
	pool *buildkitecomv1alpha1.RunnerPool,
	store *buildkitecomv1alpha1.CacheStore,
) []corev1.EnvVar {
	tokenRef := pool.Spec.AgentTokenSecretRef
	environment := make([]corev1.EnvVar, 0, 6)
	environment = append(environment,
		corev1.EnvVar{
			Name:      "BUILDKITE_AGENT_TOKEN",
			ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &tokenRef},
		},
		corev1.EnvVar{
			Name:  "BUILDKITE_AGENT_TAGS",
			Value: "queue=" + pool.Spec.Queue,
		},
		corev1.EnvVar{
			Name:  "BUILDKITE_AGENT_HEALTH_CHECK_ADDR",
			Value: fmt.Sprintf("0.0.0.0:%d", agentHealthPort),
		},
	)
	if store == nil {
		return environment
	}

	accessKeyRef := corev1.SecretKeySelector{
		LocalObjectReference: corev1.LocalObjectReference{Name: store.Spec.CredentialsSecretRef.Name},
		Key:                  store.Spec.CredentialsSecretRef.AccessKeyIDKey,
	}
	secretKeyRef := corev1.SecretKeySelector{
		LocalObjectReference: corev1.LocalObjectReference{Name: store.Spec.CredentialsSecretRef.Name},
		Key:                  store.Spec.CredentialsSecretRef.SecretAccessKeyKey,
	}
	return append(environment,
		corev1.EnvVar{Name: "BUILDKITE_AGENT_CACHE_STORE_URL", Value: cacheStoreURL(store)},
		corev1.EnvVar{
			Name:      "AWS_ACCESS_KEY_ID",
			ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &accessKeyRef},
		},
		corev1.EnvVar{
			Name:      "AWS_SECRET_ACCESS_KEY",
			ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &secretKeyRef},
		},
	)
}

func cacheStoreURL(store *buildkitecomv1alpha1.CacheStore) string {
	query := url.Values{}
	query.Set("region", garageRegion)
	query.Set("endpoint", garageS3Endpoint(store))
	query.Set("use_path_style", "true")
	return (&url.URL{
		Scheme:   "s3",
		Host:     desiredCacheBucket(store),
		RawQuery: query.Encode(),
	}).String()
}

func poolLabels(pool *buildkitecomv1alpha1.RunnerPool) map[string]string {
	return map[string]string{
		"app.kubernetes.io/name":       "buildkite-agent",
		"app.kubernetes.io/instance":   pool.Name,
		"app.kubernetes.io/managed-by": "buildkite-operator",
		poolLabel:                      pool.Name,
	}
}

func desiredImage(pool *buildkitecomv1alpha1.RunnerPool) string {
	if pool.Spec.Image != "" {
		return pool.Spec.Image
	}
	return defaultAgentImage
}

func desiredTerminationGracePeriodSeconds(pool *buildkitecomv1alpha1.RunnerPool) *int64 {
	if pool.Spec.TerminationGracePeriodSeconds != nil {
		return pool.Spec.TerminationGracePeriodSeconds
	}
	gracePeriod := defaultTerminationGracePeriodSeconds
	return &gracePeriod
}

func desiredMinIdleRunners(pool *buildkitecomv1alpha1.RunnerPool) int32 {
	if pool.Spec.MinIdleRunners != nil {
		return *pool.Spec.MinIdleRunners
	}
	return defaultMinIdleRunners
}

func desiredIdleTimeoutSeconds(pool *buildkitecomv1alpha1.RunnerPool) int32 {
	if pool.Spec.IdleTimeoutSeconds != nil {
		return *pool.Spec.IdleTimeoutSeconds
	}
	return defaultIdleTimeoutSeconds
}

// desiredResources normalizes resource requirements the same way as the API server.
func desiredResources(pool *buildkitecomv1alpha1.RunnerPool) corev1.ResourceRequirements {
	return normalizedResources(pool.Spec.Resources)
}

func normalizedResources(resources corev1.ResourceRequirements) corev1.ResourceRequirements {
	want := *resources.DeepCopy()
	if len(want.Limits) == 0 {
		return want
	}
	if want.Requests == nil {
		want.Requests = make(corev1.ResourceList, len(want.Limits))
	}
	for name, quantity := range want.Limits {
		if _, ok := want.Requests[name]; !ok {
			want.Requests[name] = quantity.DeepCopy()
		}
	}
	return want
}
