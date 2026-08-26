// Copyright (c) 2026 Buildkite Pty Ltd
// SPDX-License-Identifier: MIT

package controller

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"maps"
	"strconv"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
	ctrl "sigs.k8s.io/controller-runtime"

	buildkitecomv1alpha1 "github.com/buildkite/buildkite-operator/api/v1alpha1"
)

const supervisorScript = `set -u

agent_name="buildkite-agent"
stopping=0
log_pid=""

stop_log_follower() {
	if [ -n "$log_pid" ]; then
		kill "$log_pid" >/dev/null 2>&1 || true
		wait "$log_pid" >/dev/null 2>&1 || true
		log_pid=""
	fi
}

cleanup_containers() {
	container_ids=$(docker ps --all --quiet 2>/dev/null) || return 1
	if [ -n "$container_ids" ]; then
		docker rm --force $container_ids >/dev/null 2>&1 || return 1
	fi
}

prune_networks() {
	docker network prune --force >/dev/null 2>&1 || true
}

shutdown() {
	trap - TERM INT
	stopping=1
	stop_log_follower
	if docker info >/dev/null 2>&1; then
		stop_timeout=$((TERMINATION_GRACE_PERIOD_SECONDS - 10))
		if [ "$stop_timeout" -lt 0 ]; then
			stop_timeout=0
		fi
		docker stop --time "$stop_timeout" "$agent_name" >/dev/null 2>&1 || true
		cleanup_containers || true
	fi
	exit 0
}

trap shutdown TERM INT

wait_for_docker() {
	while ! docker info >/dev/null 2>&1; do
		if [ "$stopping" -eq 1 ]; then
			return 1
		fi
		sleep 1
	done
}

agent_running() {
	[ "$(docker inspect --format '{{.State.Running}}' "$agent_name" 2>/dev/null)" = "true" ]
}

start_agent() {
	cleanup_containers || return 1
	prune_networks

	if ! docker image inspect "$AGENT_IMAGE" >/dev/null 2>&1; then
		docker pull "$AGENT_IMAGE" || return 1
	fi

	set -- docker run --detach --pull never \
		--name "$agent_name" \
		--hostname "$POD_NAME" \
		--group-add 2375 \
		--publish 8080:8080 \
		--volume /var/run/docker.sock:/var/run/docker.sock \
		--volume /workspace:/workspace \
		--env BUILDKITE_AGENT_TOKEN \
		--env "BUILDKITE_AGENT_TAGS=$AGENT_TAGS" \
		--env "BUILDKITE_AGENT_NAME=$POD_NAME" \
		--env BUILDKITE_AGENT_HEALTH_CHECK_ADDR=0.0.0.0:8080 \
		--env BUILDKITE_BUILD_PATH=/workspace/builds \
		--env BUILDKITE_PLUGINS_PATH=/workspace/plugins \
		--env DOCKER_HOST=unix:///var/run/docker.sock

	if [ -n "${DOCKER_CONFIG:-}" ]; then
		set -- "$@" \
			--volume "$DOCKER_CONFIG:$DOCKER_CONFIG:ro" \
			--env "DOCKER_CONFIG=$DOCKER_CONFIG"
	fi

	set -- "$@" "$AGENT_IMAGE"
	"$@" >/dev/null
}

follow_agent_logs() {
	if [ "$1" = "adopted" ]; then
		docker logs --tail 0 --follow "$agent_name" &
	else
		docker logs --follow "$agent_name" &
	fi
	log_pid=$!
}

while [ "$stopping" -eq 0 ]; do
	wait_for_docker || break

	if agent_running; then
		follow_agent_logs adopted
	else
		if ! start_agent; then
			sleep 5
			continue
		fi
		follow_agent_logs new
	fi

	docker wait "$agent_name" >/dev/null 2>&1 &
	wait_pid=$!
	wait "$wait_pid" >/dev/null 2>&1 || true
	stop_log_follower

	if [ "$stopping" -eq 1 ]; then
		break
	fi
	if ! docker info >/dev/null 2>&1; then
		continue
	fi
	if agent_running; then
		continue
	fi

	cleanup_containers || true
	prune_networks
	sleep 5
done
`

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
	configSecretName := desiredConfigSecretName(pool)
	pod := corev1.PodSpec{
		AutomountServiceAccountToken:  toPtr(false),
		TerminationGracePeriodSeconds: desiredTerminationGracePeriodSeconds(pool),
		NodeSelector:                  maps.Clone(pool.Spec.NodeSelector),
		Tolerations:                   copyTolerations(pool.Spec.Tolerations),
		SecurityContext: &corev1.PodSecurityContext{
			FSGroup:            toPtr(dockerGroupID),
			SupplementalGroups: []int64{dockerGroupID},
		},
		InitContainers: []corev1.Container{dockerdContainer(pool, configSecretName != "")},
		Containers:     []corev1.Container{supervisorContainer(pool, configSecretName != "")},
		Volumes:        dockerVolumes(configSecretName),
	}
	if configSecretName != "" {
		pod.ImagePullSecrets = []corev1.LocalObjectReference{{Name: configSecretName}}
	}
	return pod
}

func dockerdContainer(pool *buildkitecomv1alpha1.RunnerPool, withDockerConfig bool) corev1.Container {
	return corev1.Container{
		Name:    dockerdContainerName,
		Image:   desiredDaemonImage(pool),
		Command: []string{"/usr/local/bin/dockerd-entrypoint.sh"},
		Args: []string{
			"dockerd",
			"--host=" + dockerHost,
			"--group=" + strconv.FormatInt(dockerGroupID, 10),
		},
		RestartPolicy:  toPtr(corev1.ContainerRestartPolicyAlways),
		StartupProbe:   dockerInfoProbe(1, 60),
		ReadinessProbe: dockerInfoProbe(5, 3),
		Env:            []corev1.EnvVar{{Name: dockerHostEnvName, Value: dockerHost}},
		Resources:      desiredResources(pool),
		VolumeMounts:   dockerVolumeMounts(withDockerConfig),
		SecurityContext: &corev1.SecurityContext{
			Privileged:   toPtr(true),
			RunAsUser:    toPtr(int64(0)),
			RunAsNonRoot: toPtr(false),
		},
	}
}

func supervisorContainer(pool *buildkitecomv1alpha1.RunnerPool, withDockerConfig bool) corev1.Container {
	return corev1.Container{
		Name:    supervisorContainerName,
		Image:   desiredSupervisorImage(pool),
		Command: []string{shellPath, "-c", supervisorScript},
		Ports: []corev1.ContainerPort{{
			Name: agentHealthPortName, ContainerPort: agentHealthPort, Protocol: corev1.ProtocolTCP,
		}},
		ReadinessProbe: &corev1.Probe{
			ProbeHandler: corev1.ProbeHandler{
				HTTPGet: &corev1.HTTPGetAction{
					Path:   "/agent/1",
					Port:   intstr.FromString(agentHealthPortName),
					Scheme: corev1.URISchemeHTTP,
				},
			},
		},
		Env:          supervisorEnv(pool, withDockerConfig),
		VolumeMounts: supervisorVolumeMounts(withDockerConfig),
		Resources: corev1.ResourceRequirements{
			Requests: corev1.ResourceList{
				corev1.ResourceCPU:    resource.MustParse("10m"),
				corev1.ResourceMemory: resource.MustParse("32Mi"),
			},
			Limits: corev1.ResourceList{
				corev1.ResourceCPU:    resource.MustParse("100m"),
				corev1.ResourceMemory: resource.MustParse("128Mi"),
			},
		},
		SecurityContext: &corev1.SecurityContext{
			Privileged:               toPtr(false),
			RunAsUser:                toPtr(supervisorUID),
			RunAsGroup:               toPtr(dockerGroupID),
			RunAsNonRoot:             toPtr(true),
			AllowPrivilegeEscalation: toPtr(false),
			Capabilities: &corev1.Capabilities{
				Drop: []corev1.Capability{"ALL"},
			},
		},
	}
}

func dockerInfoProbe(periodSeconds, failureThreshold int32) *corev1.Probe {
	return &corev1.Probe{
		ProbeHandler: corev1.ProbeHandler{
			Exec: &corev1.ExecAction{Command: []string{"docker", "info"}},
		},
		TimeoutSeconds:   1,
		PeriodSeconds:    periodSeconds,
		SuccessThreshold: 1,
		FailureThreshold: failureThreshold,
	}
}

func supervisorEnv(pool *buildkitecomv1alpha1.RunnerPool, withDockerConfig bool) []corev1.EnvVar {
	tokenRef := pool.Spec.AgentTokenSecretRef
	env := []corev1.EnvVar{
		{Name: agentImageEnvName, Value: desiredAgentImage(pool)},
		{
			Name:      "BUILDKITE_AGENT_TOKEN",
			ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &tokenRef},
		},
		{Name: "AGENT_TAGS", Value: "queue=" + pool.Spec.Queue},
		{
			Name: "POD_NAME",
			ValueFrom: &corev1.EnvVarSource{FieldRef: &corev1.ObjectFieldSelector{
				APIVersion: "v1",
				FieldPath:  "metadata.name",
			}},
		},
		{
			Name:  "TERMINATION_GRACE_PERIOD_SECONDS",
			Value: strconv.FormatInt(*desiredTerminationGracePeriodSeconds(pool), 10),
		},
		{Name: dockerHostEnvName, Value: dockerHost},
	}
	if withDockerConfig {
		env = append(env, corev1.EnvVar{Name: "DOCKER_CONFIG", Value: dockerConfigPath})
	}
	return env
}

func dockerVolumeMounts(withDockerConfig bool) []corev1.VolumeMount {
	mounts := []corev1.VolumeMount{
		{Name: dockerDataVolumeName, MountPath: "/var/lib/docker"},
		{Name: dockerRunVolumeName, MountPath: dockerRunPath},
		{Name: workspaceVolumeName, MountPath: "/workspace"},
	}
	if withDockerConfig {
		mounts = append(mounts, corev1.VolumeMount{
			Name: dockerConfigVolumeName, MountPath: dockerConfigPath, ReadOnly: true,
		})
	}
	return mounts
}

func supervisorVolumeMounts(withDockerConfig bool) []corev1.VolumeMount {
	mounts := []corev1.VolumeMount{{Name: dockerRunVolumeName, MountPath: dockerRunPath}}
	if withDockerConfig {
		mounts = append(mounts, corev1.VolumeMount{
			Name: dockerConfigVolumeName, MountPath: dockerConfigPath, ReadOnly: true,
		})
	}
	return mounts
}

func dockerVolumes(configSecretName string) []corev1.Volume {
	volumes := []corev1.Volume{
		{Name: dockerDataVolumeName, VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}}},
		{Name: dockerRunVolumeName, VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}}},
		{Name: workspaceVolumeName, VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}}},
	}
	if configSecretName != "" {
		defaultMode := int32(0o444)
		volumes = append(volumes, corev1.Volume{
			Name: dockerConfigVolumeName,
			VolumeSource: corev1.VolumeSource{Secret: &corev1.SecretVolumeSource{
				SecretName:  configSecretName,
				DefaultMode: &defaultMode,
				Items: []corev1.KeyToPath{{
					Key:  corev1.DockerConfigJsonKey,
					Path: "config.json",
				}},
			}},
		})
	}
	return volumes
}

func desiredPodTemplateHash(pool *buildkitecomv1alpha1.RunnerPool) (string, error) {
	template, err := json.Marshal(desiredAgentPodSpec(pool))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%x", sha256.Sum256(template)), nil
}

func poolLabels(pool *buildkitecomv1alpha1.RunnerPool) map[string]string {
	return map[string]string{
		"app.kubernetes.io/name":       "buildkite-agent",
		"app.kubernetes.io/instance":   pool.Name,
		"app.kubernetes.io/managed-by": "buildkite-operator",
		poolLabel:                      pool.Name,
	}
}

func desiredAgentImage(pool *buildkitecomv1alpha1.RunnerPool) string {
	if pool.Spec.AgentImage != "" {
		return pool.Spec.AgentImage
	}
	return defaultAgentImage
}

func desiredDaemonImage(pool *buildkitecomv1alpha1.RunnerPool) string {
	if pool.Spec.Docker != nil && pool.Spec.Docker.DaemonImage != "" {
		return pool.Spec.Docker.DaemonImage
	}
	return defaultDaemonImage
}

func desiredSupervisorImage(pool *buildkitecomv1alpha1.RunnerPool) string {
	if pool.Spec.Docker != nil && pool.Spec.Docker.SupervisorImage != "" {
		return pool.Spec.Docker.SupervisorImage
	}
	return defaultSupervisorImage
}

func desiredConfigSecretName(pool *buildkitecomv1alpha1.RunnerPool) string {
	if pool.Spec.Docker == nil || pool.Spec.Docker.ConfigSecretRef == nil {
		return ""
	}
	return pool.Spec.Docker.ConfigSecretRef.Name
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

func copyTolerations(tolerations []corev1.Toleration) []corev1.Toleration {
	if tolerations == nil {
		return nil
	}
	return append([]corev1.Toleration(nil), tolerations...)
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

func toPtr[T any](value T) *T {
	return &value
}
