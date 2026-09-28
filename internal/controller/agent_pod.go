// Copyright (c) 2026 Buildkite Pty Ltd
// SPDX-License-Identifier: MIT

package controller

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
	ctrl "sigs.k8s.io/controller-runtime"

	buildkitecomv1alpha1 "github.com/buildkite/buildkite-operator/api/v1alpha1"
)

func (r *RunnerPoolReconciler) agentPod(
	pool *buildkitecomv1alpha1.RunnerPool,
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
		Spec: desiredAgentPodSpec(pool),
	}
	if err := ctrl.SetControllerReference(pool, pod, r.Scheme); err != nil {
		return nil, err
	}
	return pod, nil
}

func desiredAgentPodSpec(pool *buildkitecomv1alpha1.RunnerPool) corev1.PodSpec {
	agent := corev1.Container{
		Name:      agentContainerName,
		Image:     desiredImage(pool),
		Env:       agentEnv(pool),
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
	}
	spec := corev1.PodSpec{
		TerminationGracePeriodSeconds: desiredTerminationGracePeriodSeconds(pool),
		Containers:                    []corev1.Container{agent},
	}
	if pool.Spec.Runtime == buildkitecomv1alpha1.RunnerRuntimeKata ||
		pool.Spec.Runtime == buildkitecomv1alpha1.RunnerRuntimeSysbox {
		configureDockerRuntime(pool, &spec)
	}
	return spec
}

func configureDockerRuntime(pool *buildkitecomv1alpha1.RunnerPool, spec *corev1.PodSpec) {
	runtime := string(pool.Spec.Runtime)
	runtimeClassName := "kata-qemu-runtime-rs"
	dockerArgs := []string{"dockerd", "--host=unix:///var/run/docker.sock"}
	privileged := true
	if pool.Spec.Runtime == buildkitecomv1alpha1.RunnerRuntimeSysbox {
		runtimeClassName = "sysbox-runc"
		dockerArgs = append(dockerArgs, "--storage-driver=overlay2")
		privileged = false
		hostUsers := false
		spec.HostUsers = &hostUsers
	}

	restartAlways := corev1.ContainerRestartPolicyAlways
	spec.RuntimeClassName = &runtimeClassName
	spec.AutomountServiceAccountToken = boolPtr(false)
	spec.NodeSelector = map[string]string{"experiments.buildkite.com/runtime": runtime}
	spec.Tolerations = []corev1.Toleration{{
		Key:      "experiments.buildkite.com/runtime",
		Operator: corev1.TolerationOpEqual,
		Value:    runtime,
		Effect:   corev1.TaintEffectNoSchedule,
	}}
	spec.InitContainers = []corev1.Container{{
		Name:          "dockerd",
		Image:         "docker:29.7.2-dind",
		RestartPolicy: &restartAlways,
		Args:          dockerArgs,
		Env: []corev1.EnvVar{{
			Name:  "DOCKER_HOST",
			Value: "unix:///var/run/docker.sock",
		}},
		SecurityContext: &corev1.SecurityContext{Privileged: &privileged},
		StartupProbe:    dockerInfoProbe(2, 90),
		ReadinessProbe:  dockerInfoProbe(10, 0),
		Resources: corev1.ResourceRequirements{
			Requests: corev1.ResourceList{
				corev1.ResourceCPU:              resource.MustParse("2"),
				corev1.ResourceMemory:           resource.MustParse("4Gi"),
				corev1.ResourceEphemeralStorage: resource.MustParse("15Gi"),
			},
			Limits: corev1.ResourceList{
				corev1.ResourceCPU:              resource.MustParse("4"),
				corev1.ResourceMemory:           resource.MustParse("8Gi"),
				corev1.ResourceEphemeralStorage: resource.MustParse("50Gi"),
			},
		},
		VolumeMounts: []corev1.VolumeMount{
			{Name: "docker-data", MountPath: "/var/lib/docker"},
			{Name: dockerRunVolumeName, MountPath: "/var/run"},
			{Name: workspaceVolumeName, MountPath: workspaceMountPath},
		},
	}}
	spec.Volumes = []corev1.Volume{
		{Name: "docker-data", VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{SizeLimit: quantityPtr("40Gi")}}},
		{Name: dockerRunVolumeName, VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{Medium: corev1.StorageMediumMemory, SizeLimit: quantityPtr("16Mi")}}},
		{Name: workspaceVolumeName, VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{SizeLimit: quantityPtr("10Gi")}}},
	}

	agent := &spec.Containers[0]
	agent.Env = append(agent.Env,
		corev1.EnvVar{Name: "BUILDKITE_AGENT_CONFIG", Value: "/dev/null"},
		corev1.EnvVar{Name: "BUILDKITE_AGENT_NAME", ValueFrom: &corev1.EnvVarSource{FieldRef: &corev1.ObjectFieldSelector{FieldPath: "metadata.name"}}},
		corev1.EnvVar{Name: "BUILDKITE_BUILD_PATH", Value: "/buildkite/builds"},
		corev1.EnvVar{Name: "BUILDKITE_PLUGINS_PATH", Value: "/buildkite/plugins"},
		corev1.EnvVar{Name: "BUILDKITE_SOCKETS_PATH", Value: "/buildkite/sockets"},
		corev1.EnvVar{Name: "DOCKER_HOST", Value: "unix:///var/run/docker.sock"},
	)
	agent.SecurityContext = &corev1.SecurityContext{
		AllowPrivilegeEscalation: boolPtr(false),
		Privileged:               boolPtr(false),
	}
	agent.VolumeMounts = []corev1.VolumeMount{
		{Name: dockerRunVolumeName, MountPath: "/var/run"},
		{Name: workspaceVolumeName, MountPath: workspaceMountPath},
	}
}

func dockerInfoProbe(periodSeconds, failureThreshold int32) *corev1.Probe {
	return &corev1.Probe{
		ProbeHandler:     corev1.ProbeHandler{Exec: &corev1.ExecAction{Command: []string{"docker", "info"}}},
		PeriodSeconds:    periodSeconds,
		TimeoutSeconds:   5,
		FailureThreshold: failureThreshold,
	}
}

func quantityPtr(value string) *resource.Quantity {
	quantity := resource.MustParse(value)
	return &quantity
}

func boolPtr(value bool) *bool {
	return &value
}

func desiredPodTemplateHash(pool *buildkitecomv1alpha1.RunnerPool) (string, error) {
	template, err := json.Marshal(desiredAgentPodSpec(pool))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%x", sha256.Sum256(template)), nil
}

// agentEnv is the environment every agent in the pool runs with.
func agentEnv(pool *buildkitecomv1alpha1.RunnerPool) []corev1.EnvVar {
	tokenRef := pool.Spec.AgentTokenSecretRef
	tags := "queue=" + pool.Spec.Queue
	if pool.Spec.Runtime == buildkitecomv1alpha1.RunnerRuntimeKata ||
		pool.Spec.Runtime == buildkitecomv1alpha1.RunnerRuntimeSysbox {
		tags += ",runtime=" + string(pool.Spec.Runtime)
	}
	return []corev1.EnvVar{
		{
			Name:      "BUILDKITE_AGENT_TOKEN",
			ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &tokenRef},
		},
		{
			Name:  agentTagsEnvName,
			Value: tags,
		},
		{
			Name:  "BUILDKITE_AGENT_HEALTH_CHECK_ADDR",
			Value: fmt.Sprintf("0.0.0.0:%d", agentHealthPort),
		},
	}
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
	want := *pool.Spec.Resources.DeepCopy()
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
