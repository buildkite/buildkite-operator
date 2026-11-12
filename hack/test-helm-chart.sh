#!/usr/bin/env bash

set -euo pipefail

HELM="${HELM:-helm}"
CHART_DIR="${HELM_CHART_DIR:-charts/buildkite-operator}"
TOKEN="chart-test-agent-token"
KEDA_API_VERSIONS=(
	--api-versions keda.sh/v1alpha1/ScaledObject
	--api-versions keda.sh/v1alpha1/TriggerAuthentication
)

render() {
	"${HELM}" template test "${CHART_DIR}" \
		--namespace buildkite-runners \
		"${KEDA_API_VERSIONS[@]}" \
		--set-string runnerPools.linux.queue=linux \
		--set runnerPools.linux.maxReplicas=4 \
		"$@"
}

assert_contains() {
	local output="$1"
	local expected="$2"
	if [[ "${output}" != *"${expected}"* ]]; then
		echo "Expected rendered chart to contain: ${expected}" >&2
		exit 1
	fi
}

assert_fails() {
	local expected="$1"
	shift
	local output
	if output=$("${HELM}" template test "${CHART_DIR}" "${KEDA_API_VERSIONS[@]}" "$@" 2>&1); then
		echo "Expected Helm rendering to fail" >&2
		exit 1
	fi
	assert_contains "${output}" "${expected}"
}

# Print the rendered document of the given kind and name.
document() {
	awk -v kind="$2" -v name="$3" '
		/^---$/ { if (doc ~ "\nkind: " kind "\n" && doc ~ "\n  name: " name "\n") printf "%s", doc; doc = "\n"; next }
		{ doc = doc $0 "\n" }
		END { if (doc ~ "\nkind: " kind "\n" && doc ~ "\n  name: " name "\n") printf "%s", doc }' <<<"$1"
}

if missing_keda=$("${HELM}" template test "${CHART_DIR}" \
	--set-string runnerPools.linux.queue=linux \
	--set runnerPools.linux.maxReplicas=4 \
	--set-string agentToken.value="${TOKEN}" 2>&1); then
	echo "Expected rendering without KEDA APIs to fail" >&2
	exit 1
fi
assert_contains "${missing_keda}" "KEDA is required"

if missing_auth=$("${HELM}" template test "${CHART_DIR}" \
	--api-versions keda.sh/v1alpha1/ScaledObject \
	--set-string runnerPools.linux.queue=linux \
	--set runnerPools.linux.maxReplicas=4 \
	--set-string agentToken.value="${TOKEN}" 2>&1); then
	echo "Expected rendering without the TriggerAuthentication API to fail" >&2
	exit 1
fi
assert_contains "${missing_auth}" "keda.sh/v1alpha1/TriggerAuthentication API is not available"

direct=$(render --set-string agentToken.value="${TOKEN}")
assert_contains "${direct}" "# Source: buildkite-operator-chart/templates/runners.yaml"
assert_contains "${direct}" "kind: Deployment"
assert_contains "${direct}" "kind: ScaledObject"
assert_contains "${direct}" "kind: TriggerAuthentication"
assert_contains "${direct}" "type: RollingUpdate"
assert_contains "${direct}" "maxUnavailable: 0"
assert_contains "${direct}" "maxSurge: 1"
assert_contains "${direct}" 'controller.kubernetes.io/pod-deletion-cost: "100"'
assert_contains "${direct}" 'cluster-autoscaler.kubernetes.io/safe-to-evict: "false"'
assert_contains "${direct}" 'SAFE_TO_EVICT = "cluster-autoscaler.kubernetes.io/safe-to-evict"'
assert_contains "${direct}" "serviceAccountName: test-buildkite-operator-deletion-cost"
assert_contains "${direct}" "name: test-linux"
assert_contains "${direct}" 'buildkite.com/runner-pool: "linux"'
assert_contains "${direct}" "- name: deletion-cost"
assert_contains "${direct}" "kind: Role"
assert_contains "${direct}" 'verbs: ["patch"]'
# The Role can't limit patch to the sidecar's own Pod, so a cluster-scoped
# admission policy, named per namespace and release, does. The e2e test checks
# what it admits.
deletion_cost_policy=$(document "${direct}" ValidatingAdmissionPolicy buildkite-runners-test-buildkite-operator-deletion-cost)
assert_contains "${deletion_cost_policy}" "kubernetes.io/metadata.name: buildkite-runners"
assert_contains "${deletion_cost_policy}" 'request.userInfo.username == "system:serviceaccount:buildkite-runners:test-buildkite-operator-deletion-cost"'
assert_contains "$(document "${direct}" ValidatingAdmissionPolicyBinding buildkite-runners-test-buildkite-operator-deletion-cost)" \
	$'policyName: buildkite-runners-test-buildkite-operator-deletion-cost\n  validationActions: [Deny]'
if [[ "$(render --set-string agentToken.value="${TOKEN}" --set deletionCost.admissionPolicy.enabled=false)" == *"kind: ValidatingAdmissionPolicy"* ]]; then
	echo "Deletion-cost admission policy rendered while disabled" >&2
	exit 1
fi
assert_contains "${direct}" "def agent_busy():"
assert_contains "${direct}" 'image: "python:3.12.14-alpine3.24@sha256:4c47124a8391cb7a9f571164147d154777cf012a4ece5f86097130d7a4478111"'
[[ $(grep -c 'mountPath: /var/run/secrets/kubernetes.io/serviceaccount' <<<"${direct}") -eq 1 ]] || {
	echo "Kubernetes API token was mounted into more than the deletion-cost sidecar" >&2
	exit 1
}
assert_contains "${direct}" 'value: "queue=linux,runtime=standard"'
assert_contains "${direct}" "value: /buildkite/builds"
assert_contains "${direct}" "value: /buildkite/plugins"
assert_contains "${direct}" "checksum/agent-token:"
rotated=$(render --set-string agentToken.value="${TOKEN}-rotated")
if [[ $(grep 'checksum/agent-token:' <<<"${direct}") == $(grep 'checksum/agent-token:' <<<"${rotated}") ]]; then
	echo "Agent token rotation did not change the Pod template" >&2
	exit 1
fi
assert_contains "${direct}" "minReplicaCount: 1"
assert_contains "${direct}" "maxReplicaCount: 4"
assert_contains "${direct}" 'formula: "scheduled + running"'
assert_contains "${direct}" 'target: "1"'
assert_contains "${direct}" 'activationTarget: "0"'
assert_contains "${direct}" 'metricType: AverageValue'
assert_contains "${direct}" $'scaleDown:\n          stabilizationWindowSeconds: 60\n'
assert_contains "${direct}" 'valueLocation: "jobs.queues.linux.scheduled"'
assert_contains "${direct}" "token: \"${TOKEN}\""
assert_contains "${direct}" "authorization: \"Token ${TOKEN}\""
if [[ "${direct}" == *$'\n  replicas:'* ]]; then
	echo "Deployment rendered spec.replicas even though KEDA owns scaling" >&2
	exit 1
fi
if [[ "${direct}" == *"ephemeral-agent"* ]]; then
	echo "Persistent agents rendered the ephemeral agent loop" >&2
	exit 1
fi

# Rollout budgets inherit independently, and a pool can override either with
# zero. Counts stay numbers and percentages stay strings in the Deployment.
rollout=$(render --set-string agentToken.value="${TOKEN}" \
	--set defaults.rollingUpdate.maxUnavailable=2 \
	--set defaults.rollingUpdate.maxSurge=20 \
	--set runnerPools.linux.rollingUpdate.maxUnavailable=0 \
	--set-string runnerPools.linux.rollingUpdate.maxSurge=30% \
	--set-string runnerPools.inherited.queue=inherited --set runnerPools.inherited.maxReplicas=100 \
	--set-string runnerPools.no-surge.queue=no-surge --set runnerPools.no-surge.maxReplicas=100 \
	--set-string runnerPools.no-surge.rollingUpdate.maxUnavailable=20% \
	--set runnerPools.no-surge.rollingUpdate.maxSurge=0)
assert_contains "$(document "${rollout}" Deployment test-linux)" \
	$'maxUnavailable: 0\n      maxSurge: 30%'
assert_contains "$(document "${rollout}" Deployment test-inherited)" \
	$'maxUnavailable: 2\n      maxSurge: 20'
assert_contains "$(document "${rollout}" Deployment test-no-surge)" \
	$'maxUnavailable: 20%\n      maxSurge: 0'
partial_rollout=$(render --set-string agentToken.value="${TOKEN}" \
	--set defaults.rollingUpdate.maxSurge=20 \
	--set runnerPools.linux.rollingUpdate.maxUnavailable=3)
assert_contains "$(document "${partial_rollout}" Deployment test-linux)" \
	$'maxUnavailable: 3\n      maxSurge: 20'
for field in maxUnavailable maxSurge; do
	for invalid in -1 1.5 true; do
		assert_fails "rollingUpdate" --set "defaults.rollingUpdate.${field}=${invalid}"
	done
	for invalid in 20 -10% 1.5%; do
		assert_fails "rollingUpdate" --set-string "runnerPools.linux.rollingUpdate.${field}=${invalid}"
	done
done
assert_fails "rollingUpdate" --set-string defaults.rollingUpdate.maxUnavailable=101%
for zero in 0 0%; do
	assert_fails "runnerPools.linux.rollingUpdate.maxUnavailable and maxSurge must not both be zero" \
		--set-string runnerPools.linux.queue=linux --set runnerPools.linux.maxReplicas=4 \
		--set-string defaults.rollingUpdate.maxUnavailable=0% \
		--set runnerPools.linux.rollingUpdate.maxSurge="${zero}"
done

direct_with_reserved_key=$(render \
	--set-string agentToken.value="${TOKEN}" \
	--set-string agentToken.existingSecret.key=authorization)
assert_contains "${direct_with_reserved_key}" "token: \"${TOKEN}\""
if [[ $(grep -c '^  authorization:' <<<"${direct_with_reserved_key}") -ne 1 ]]; then
	echo "Generated Secret rendered the authorization key more than once" >&2
	exit 1
fi

existing=$(render \
	--set-string agentToken.existingSecret.name=agent-token \
	--set-string metricsToken.existingSecret.name=metrics-token)
assert_contains "${existing}" 'name: "agent-token"'
assert_contains "${existing}" "name: metrics-token"
assert_contains "${existing}" "value: /buildkite/builds"
if [[ "${existing}" == *"kind: Secret"* ]]; then
	echo "Existing Secret mode rendered a token Secret" >&2
	exit 1
fi

kata=$(render --set-string agentToken.value="${TOKEN}" --set-string runnerPools.linux.runtime=kata)
assert_contains "${kata}" "runtimeClassName: kata-qemu-runtime-rs"
assert_contains "${kata}" "privileged: true"
assert_contains "${kata}" 'value: "queue=linux,runtime=kata"'
assert_contains "${kata}" "- name: deletion-cost-code"
assert_contains "${kata}" "- name: dockerd-data"
assert_contains "${kata}" 'cluster-autoscaler.kubernetes.io/safe-to-evict: "false"'

sysbox=$(render --set-string agentToken.value="${TOKEN}" --set-string runnerPools.linux.runtime=sysbox)
assert_contains "${sysbox}" "runtimeClassName: sysbox-runc"
assert_contains "${sysbox}" "hostUsers: false"
assert_contains "${sysbox}" "- --storage-driver=overlay2"
assert_contains "${sysbox}" 'value: "queue=linux,runtime=sysbox"'
if [[ "${sysbox}" == *"name: supervisor"* ]]; then
	echo "Persistent agents rendered the ephemeral-agent supervisor" >&2
	exit 1
fi

# dind runs the same Docker daemon sidecar, privileged and without a
# RuntimeClass, node selector or toleration, so it schedules on any node.
dind=$(render --set-string agentToken.value="${TOKEN}" --set-string runnerPools.linux.runtime=dind)
dind_runner=$(document "${dind}" Deployment test-linux)
assert_contains "${dind_runner}" "- name: dockerd"
assert_contains "${dind_runner}" $'securityContext:\n            privileged: true'
assert_contains "${dind_runner}" "- name: agent"
assert_contains "${dind_runner}" 'value: "queue=linux,runtime=dind"'
assert_contains "${dind_runner}" "value: unix:///var/run/docker.sock"
assert_contains "${dind_runner}" "- name: dockerd-data"
assert_contains "${dind_runner}" 'cluster-autoscaler.kubernetes.io/safe-to-evict: "false"'
for unexpected in "runtimeClassName:" "nodeSelector:" "tolerations:" "hostUsers:" "--storage-driver" "- name: supervisor"; do
	if [[ "${dind_runner}" == *"${unexpected}"* ]]; then
		echo "dind runners rendered ${unexpected}" >&2
		exit 1
	fi
done
ephemeral_dind=$(render --set-string agentToken.value="${TOKEN}" --set-string runnerPools.linux.runtime=dind --set runnerPools.linux.ephemeralAgent=true)
ephemeral_dind_runner=$(document "${ephemeral_dind}" Deployment test-linux)
assert_contains "${ephemeral_dind_runner}" "- name: supervisor"
assert_contains "${ephemeral_dind_runner}" "- name: dockerd"
assert_contains "${ephemeral_dind_runner}" "checksum/supervisor:"
if [[ "${ephemeral_dind_runner}" == *"- name: agent"* || "${ephemeral_dind_runner}" == *"runtimeClassName:"* ]]; then
	echo "Ephemeral dind agents rendered an agent container or RuntimeClass" >&2
	exit 1
fi
[[ $(grep -c 'privileged: true' <<<"${ephemeral_dind_runner}") -eq 1 ]] || {
	echo "Only the dind Docker daemon should be privileged" >&2
	exit 1
}

# Pruning uses the data volume's budget, not the backing filesystem capacity.
assert_contains "${ephemeral_dind_runner}" $'- name: DOCKER_PRUNE_THRESHOLD_KIB\n              value: "29360128"'
supervisor=$(awk '/^        - name: supervisor$/,/^        - name: deletion-cost$/' <<<"${ephemeral_dind_runner}")
assert_contains "${supervisor}" 'drop: [ALL]'
if [[ "${supervisor}" == *'add:'* || "${supervisor}" == *'mountPath: /var/lib/docker'* ]]; then
	echo "Supervisor must not add capabilities or mount Docker data" >&2
	exit 1
fi
for quantity_expected in '1.5Gi:786432' '1500M:732422' '1500000000:732422' '15e8:732422'; do
	quantity=${quantity_expected%:*}
	expected=${quantity_expected#*:}
	custom_prune=$(render --set-string agentToken.value="${TOKEN}" --set-string runnerPools.linux.runtime=dind \
		--set runnerPools.linux.ephemeralAgent=true --set defaults.docker.pruneThresholdPercent=90 \
		--set runnerPools.linux.docker.pruneThresholdPercent=50 \
		--set-string runnerPools.linux.docker.storage.data="${quantity}")
	assert_contains "${custom_prune}" $'- name: DOCKER_PRUNE_THRESHOLD_KIB\n              value: '"\"${expected}\""
done
for invalid_threshold in 0 101 62.5; do
	assert_fails 'pruneThresholdPercent' --set-string agentToken.value="${TOKEN}" \
		--set runnerPools.linux.docker.pruneThresholdPercent="${invalid_threshold}"
done

# The merged volume budgets must fit the Docker limit, not its request. Include
# Docker config's 16Mi but exclude the memory-backed socket's 16Mi.
for runtime in dind kata sysbox; do
	for ephemeral_agent in false true; do
		storage_args=(--set-string agentToken.value="${TOKEN}" --set-string runnerPools.linux.queue=linux \
			--set runnerPools.linux.maxReplicas=4 --set-string runnerPools.linux.runtime="${runtime}" \
			--set runnerPools.linux.ephemeralAgent="${ephemeral_agent}" \
			--set-string defaults.docker.storage.data=1Gi --set-string runnerPools.linux.docker.storage.workspace=512Mi \
			--set-string runnerPools.linux.docker.resources.requests.ephemeral-storage=1Mi)
		storage_boundary=$(render "${storage_args[@]}" --set-string runnerPools.linux.docker.resources.limits.ephemeral-storage=1552Mi)
		assert_contains "${storage_boundary}" 'sizeLimit: 1Gi'
		assert_fails 'runnerPools.linux: docker.storage.data (1Gi) + docker.storage.workspace (512Mi) + docker-config (16Mi) exceeds' \
			"${storage_args[@]}" --set-string runnerPools.linux.docker.resources.limits.ephemeral-storage=1627389951
	done
done
for cleared_limit in docker.resources.limits docker.resources.limits.ephemeral-storage; do
	unlimited_storage=$(render --set-string agentToken.value="${TOKEN}" --set-string runnerPools.linux.runtime=dind \
		--set runnerPools.linux.ephemeralAgent=true --set-string runnerPools.linux.docker.storage.data=100Gi \
		--set "runnerPools.linux.${cleared_limit}=null")
	assert_contains "${unlimited_storage}" 'sizeLimit: 100Gi'
done
assert_fails 'exceeds docker.resources.limits.ephemeral-storage (50Gi)' \
	--set-string agentToken.value="${TOKEN}" --set-string runnerPools.linux.queue=linux \
	--set runnerPools.linux.maxReplicas=4 --set-string runnerPools.linux.runtime=dind \
	--set-string runnerPools.linux.docker.storage.data=40Gi
# Docker settings are unused by the standard runtime.
render --set-string agentToken.value="${TOKEN}" --set-string runnerPools.linux.docker.storage.data=100Gi >/dev/null

ephemeral=$(render --set-string agentToken.value="${TOKEN}" --set-string runnerPools.linux.runtime=sysbox --set runnerPools.linux.ephemeralAgent=true)
assert_contains "${ephemeral}" "- name: supervisor"
assert_contains "${ephemeral}" 'command: ["/bin/sh", "/opt/ephemeral-agent/supervisor.sh"]'
assert_contains "${ephemeral}" "name: test-buildkite-operator-ephemeral-agent"
assert_contains "${ephemeral}" 'image: "docker:29.7.2-cli@sha256:3f4743208d2338c934d7b8bcfbe1bb54c0b2355c510ad5e0f31c0c4a54bd704e"'
assert_contains "${ephemeral}" 'value: "buildkite/agent:4"'
assert_contains "${ephemeral}" "checksum/supervisor:"
assert_contains "${ephemeral}" "start --disconnect-after-job"
assert_contains "${ephemeral}" "- name: dockerd"
if [[ "${ephemeral}" == *"- name: agent"* || "${ephemeral}" == *"checksum/ephemeral-agent:"* ]]; then
	echo "Ephemeral sysbox agents also rendered an agent container" >&2
	exit 1
fi
ephemeral_kata=$(render --set-string agentToken.value="${TOKEN}" --set-string runnerPools.linux.runtime=kata --set runnerPools.linux.ephemeralAgent=true)
assert_contains "${ephemeral_kata}" "runtimeClassName: kata-qemu-runtime-rs"
assert_contains "${ephemeral_kata}" "- name: supervisor"

# Clearing inherited Docker limits must render without exposing a CPU limit,
# for both the persistent agent and the ephemeral supervisor.
for ephemeral_agent in false true; do
	cpu_args=(--set-string agentToken.value="${TOKEN}" --set-string runnerPools.linux.runtime=sysbox \
		--set runnerPools.linux.ephemeralAgent="${ephemeral_agent}")
	cpu_limited=$(document "$(render "${cpu_args[@]}" --set-string runnerPools.linux.docker.resources.limits.cpu=1500m)" Deployment test-linux)
	assert_contains "${cpu_limited}" $'- name: RUNNER_CPU_LIMIT_MILLICORES\n              valueFrom:\n                resourceFieldRef:\n                  containerName: dockerd\n                  resource: limits.cpu\n                  divisor: 1m'
	cpu_unlimited=$(document "$(render "${cpu_args[@]}" --set runnerPools.linux.docker.resources.limits=null)" Deployment test-linux)
	assert_contains "${cpu_unlimited}" 'limits: null'
	if [[ "${cpu_unlimited}" == *'RUNNER_CPU_LIMIT_MILLICORES'* ]]; then
		echo "Runner with cleared Docker limits exposed a CPU limit" >&2
		exit 1
	fi
done

# Runtime composition is only meaningful for supervised Docker agents. Keep
# the source image separate and select the image-mount-capable store explicitly.
runtime_args=(--set-string agentToken.value="${TOKEN}" --set runnerPools.linux.ephemeralAgent=true \
	--set-string runnerPools.linux.queue=linux --set runnerPools.linux.maxReplicas=4 \
	--set-string defaults.docker.agentRuntimeImage=example/runtime:noble)
for runtime in dind kata sysbox; do
	composed=$(document "$(render "${runtime_args[@]}" --set-string runnerPools.linux.runtime="${runtime}")" Deployment test-linux)
	assert_contains "${composed}" $'- name: AGENT_RUNTIME_IMAGE\n              value: "example/runtime:noble"'
	assert_contains "${composed}" $'- name: AGENT_IMAGE\n              value: "buildkite/agent:4"'
	assert_contains "${composed}" '- --feature=containerd-snapshotter=true'
	if [[ "${composed}" == *'--storage-driver=overlay2'* ]]; then
		echo "Composed agents selected the incompatible classic image store" >&2
		exit 1
	fi
done
runtime_override=$(render "${runtime_args[@]}" --set-string runnerPools.linux.runtime=dind \
	--set-string runnerPools.linux.docker.agentRuntimeImage=example/queue:ubuntu --set runnerPools.linux.docker.stepImages=false)
assert_contains "$(document "${runtime_override}" Deployment test-linux)" $'- name: AGENT_RUNTIME_IMAGE\n              value: "example/queue:ubuntu"'
runtime_cleared=$(document "$(render "${runtime_args[@]}" --set-string runnerPools.linux.runtime=sysbox \
	--set-string runnerPools.linux.docker.agentRuntimeImage=)" Deployment test-linux)
assert_contains "${runtime_cleared}" '- --storage-driver=overlay2'
if [[ "${runtime_cleared}${ephemeral_dind_runner}" == *'AGENT_RUNTIME_IMAGE'* ]]; then
	echo "An unset runtime image changed the supervisor environment" >&2
	exit 1
fi
assert_fails 'agentRuntimeImage requires ephemeralAgent' "${runtime_args[@]}" --set-string runnerPools.linux.runtime=standard
assert_fails 'agentRuntimeImage requires ephemeralAgent' "${runtime_args[@]}" --set-string runnerPools.linux.runtime=dind --set runnerPools.linux.ephemeralAgent=false
assert_fails 'agentRuntimeImage' --set defaults.docker.agentRuntimeImage=42

# Standard ephemeral agents restart in a loop inside the agent container, which
# keeps the agent's own resources.
ephemeral_standard=$(render --set-string agentToken.value="${TOKEN}" --set runnerPools.linux.ephemeralAgent=true \
	--set-string runnerPools.linux.resources.limits.memory=2Gi)
standard_runner=$(document "${ephemeral_standard}" Deployment test-linux)
assert_contains "${standard_runner}" "- name: agent"
assert_contains "${standard_runner}" 'command: ["/bin/sh", "/opt/ephemeral-agent/ephemeral-agent.sh"]'
assert_contains "${standard_runner}" "checksum/ephemeral-agent:"
assert_contains "${standard_runner}" 'value: "queue=linux,runtime=standard"'
assert_contains "${standard_runner}" "value: /buildkite/plugins"
assert_contains "${standard_runner}" "memory: 2Gi"
assert_contains "${standard_runner}" $'- name: ephemeral-agent-scripts\n              mountPath: /opt/ephemeral-agent'
assert_contains "${standard_runner}" 'cluster-autoscaler.kubernetes.io/safe-to-evict: "false"'
assert_contains "${standard_runner}" "- name: deletion-cost"
assert_contains "${ephemeral_standard}" "start --disconnect-after-job"
assert_contains "${ephemeral_standard}" 'clean_workspace() {'
for unexpected in "- name: supervisor" "- name: dockerd" "checksum/supervisor:" 'args: ["start"]' "runtimeClassName:"; do
	if [[ "${standard_runner}" == *"${unexpected}"* ]]; then
		echo "Standard ephemeral agents rendered ${unexpected}" >&2
		exit 1
	fi
done
# The workspace wipe would be unbounded without these paths.
for env in BUILDKITE_AGENT_NAME BUILDKITE_BUILD_PATH BUILDKITE_PLUGINS_PATH; do
	assert_contains "${standard_runner}" "- name: ${env}"
done
inherited=$(render --set-string agentToken.value="${TOKEN}" --set defaults.ephemeralAgent=true)
assert_contains "${inherited}" 'command: ["/bin/sh", "/opt/ephemeral-agent/ephemeral-agent.sh"]'

# Runner pools inherit defaults and override any field. Shared resources are
# rendered once; each entry gets its own Deployment and ScaledObject.
multi=$("${HELM}" template test "${CHART_DIR}" \
	--namespace buildkite-runners \
	"${KEDA_API_VERSIONS[@]}" \
	--set-string agentToken.value="${TOKEN}" \
	--set defaults.minReplicas=2 \
	--set defaults.scaleDownStabilizationWindowSeconds=120 \
	--set-string runnerPools.linux-kata.queue=linux \
	--set-string runnerPools.linux-kata.runtime=kata \
	--set runnerPools.linux-kata.maxReplicas=10 \
	--set-string runnerPools.build-sysbox.queue=build \
	--set-string runnerPools.build-sysbox.runtime=sysbox \
	--set runnerPools.build-sysbox.ephemeralAgent=true \
	--set runnerPools.build-sysbox.minReplicas=0 \
	--set runnerPools.build-sysbox.maxReplicas=4 \
	--set runnerPools.build-sysbox.scaleDownStabilizationWindowSeconds=0 \
	--set-string runnerPools.build-sysbox.docker.resources.limits.memory=16Gi)
count_kind() { grep -c "^kind: $2\$" <<<"$1" || true; }
for kind in Secret TriggerAuthentication ServiceAccount Role RoleBinding ValidatingAdmissionPolicy ValidatingAdmissionPolicyBinding; do
	[[ $(count_kind "${multi}" "${kind}") -eq 1 ]] || { echo "Expected one shared ${kind}" >&2; exit 1; }
done
[[ $(count_kind "${multi}" Deployment) -eq 2 && $(count_kind "${multi}" ScaledObject) -eq 2 ]] || {
	echo "Expected one Deployment and ScaledObject per runner pool" >&2
	exit 1
}
kata_runner=$(document "${multi}" Deployment test-linux-kata)
sysbox_runner=$(document "${multi}" Deployment test-build-sysbox)
assert_contains "${kata_runner}" "runtimeClassName: kata-qemu-runtime-rs"
assert_contains "${kata_runner}" "- name: agent"
assert_contains "${kata_runner}" 'value: "queue=linux,runtime=kata"'
assert_contains "${kata_runner}" 'buildkite.com/runner-pool: "linux-kata"'
assert_contains "${kata_runner}" "memory: 8Gi"
assert_contains "${sysbox_runner}" "runtimeClassName: sysbox-runc"
assert_contains "${sysbox_runner}" "- name: supervisor"
assert_contains "${sysbox_runner}" 'value: "queue=build,runtime=sysbox"'
assert_contains "${sysbox_runner}" 'buildkite.com/runner-pool: "build-sysbox"'
assert_contains "${sysbox_runner}" "memory: 16Gi"
assert_contains "${sysbox_runner}" 'cpu: "4"' # Inherited alongside the memory override.
# Each Deployment must select only its own entry's Pods; otherwise a release's
# Deployments would adopt each other's runners.
for entry in linux-kata build-sysbox; do
	selector=$(document "${multi}" Deployment "test-${entry}" | awk '/^  selector:$/ { found = 1; next } found && /^  [^ ]/ { found = 0 } found { print }')
	assert_contains "${selector}" "buildkite.com/runner-pool: \"${entry}\""
done
kata_scaling=$(document "${multi}" ScaledObject test-linux-kata)
sysbox_scaling=$(document "${multi}" ScaledObject test-build-sysbox)
assert_contains "${kata_scaling}" "minReplicaCount: 2" # Inherited from defaults.
assert_contains "${kata_scaling}" "maxReplicaCount: 10"
assert_contains "${kata_scaling}" $'scaleDown:\n          stabilizationWindowSeconds: 120\n' # Inherited from defaults.
assert_contains "${kata_scaling}" 'valueLocation: "jobs.queues.linux.running"'
assert_contains "${sysbox_scaling}" "minReplicaCount: 0" # Overridden to zero.
assert_contains "${sysbox_scaling}" "maxReplicaCount: 4"
assert_contains "${sysbox_scaling}" $'scaleDown:\n          stabilizationWindowSeconds: 0\n' # Overridden to zero.
assert_contains "${sysbox_scaling}" 'valueLocation: "jobs.queues.build.scheduled"'
assert_contains "${multi}" "name: test-buildkite-operator-ephemeral-agent"

# Pools sharing a queue inherit or override the formula independently.
# Conditional expressions must stay strings, and KEDA's other settings stay fixed.
shared_queue=$(render --set-string agentToken.value="${TOKEN}" \
	--set-string 'defaults.scalingFormula=(scheduled + running) * 0.75' \
	--set-string 'runnerPools.linux.scalingFormula=scheduled > 0 ? (scheduled + running) * 0.25 : running' \
	--set-string runnerPools.secondary.queue=linux --set runnerPools.secondary.maxReplicas=12)
primary_scaling=$(document "${shared_queue}" ScaledObject test-linux)
secondary_scaling=$(document "${shared_queue}" ScaledObject test-secondary)
assert_contains "${primary_scaling}" 'formula: "scheduled > 0 ? (scheduled + running) * 0.25 : running"'
assert_contains "${secondary_scaling}" 'formula: "(scheduled + running) * 0.75"'
for pool in linux secondary; do
	assert_contains "$(document "${shared_queue}" ScaledObject "test-${pool}")" 'target: "1"'
	assert_contains "$(document "${shared_queue}" ScaledObject "test-${pool}")" 'activationTarget: "0"'
	assert_contains "$(document "${shared_queue}" ScaledObject "test-${pool}")" 'metricType: AverageValue'
	assert_contains "$(document "${shared_queue}" Deployment "test-${pool}")" 'value: "queue=linux,runtime=standard"'
	assert_contains "$(document "${shared_queue}" ScaledObject "test-${pool}")" 'valueLocation: "jobs.queues.linux.scheduled"'
	assert_contains "$(document "${shared_queue}" ScaledObject "test-${pool}")" 'valueLocation: "jobs.queues.linux.running"'
done

# The accelerator serves Docker-backed entries that have not opted out.
accel_args=(
	--set-string agentToken.value="${TOKEN}"
	--set ociAccelerator.enabled=true
	--set-string ociAccelerator.ca.existingSecret.name=oci-ca
)
if [[ "${kata}" == *"oci-accelerator"* ]]; then
	echo "The accelerator rendered while disabled" >&2
	exit 1
fi
accel=$(render "${accel_args[@]}" --set-string runnerPools.linux.runtime=sysbox \
	--set ociAccelerator.noProxy='{registry.internal:5000}' \
	--set-string ociAccelerator.extraEnv.OCI_ACCELERATOR_CACHE_MAX_FILLS=32)
[[ $(count_kind "${accel}" Service) -eq 2 && $(count_kind "${accel}" NetworkPolicy) -eq 1 ]] || {
	echo "Expected accelerator and headless Services and one accelerator NetworkPolicy" >&2
	exit 1
}
[[ $(count_kind "${accel}" Deployment) -eq 1 && $(count_kind "${accel}" StatefulSet) -eq 1 ]] || {
	echo "Expected a runner Deployment and an accelerator StatefulSet" >&2
	exit 1
}
if [[ "${accel}" == *"PersistentVolumeClaim"* || "${accel}" == *"volumeClaimTemplates"* ]]; then
	echo "The accelerator rendered persistent storage" >&2
	exit 1
fi
accel_runner=$(document "${accel}" Deployment test-linux)
assert_contains "${accel_runner}" "- --https-proxy=http://test-buildkite-operator-oci-accelerator.buildkite-runners.svc:5128"
assert_contains "${accel_runner}" "- --no-proxy=registry.internal:5000"
assert_contains "${accel_runner}" $'- name: SSL_CERT_DIR\n              value: /etc/ssl/certs:/etc/ssl/oci-accelerator-certs'
ca_cert_volume=$'- name: oci-accelerator-ca\n          configMap:\n            name: "test-buildkite-operator-oci-accelerator-ca-cert"'
assert_contains "${accel_runner}" "${ca_cert_volume}"
if [[ "${accel_runner}" == *'"oci-ca"'* || "${accel_runner}" == *'"ca.key"'* ]]; then
	echo "Runner Pods referenced the accelerator CA Secret" >&2
	exit 1
fi
accel_proxy=$(document "${accel}" StatefulSet test-buildkite-operator-oci-accelerator)
assert_contains "${accel_proxy}" $'OCI_ACCELERATOR_LISTEN\n              value: 0.0.0.0:5128'
assert_contains "${accel_proxy}" $'- name: proxy\n              containerPort: 5128'
for service in test-buildkite-operator-oci-accelerator test-buildkite-operator-oci-accelerator-peers; do
	assert_contains "$(document "${accel}" Service "${service}")" $'- name: proxy\n      port: 5128\n      targetPort: proxy'
done
assert_contains "${accel_proxy}" 'image: "buildkite/oci-accelerator:v0.5.0@sha256:c671b75f349cf625fdd7555c632f17782d6b98ed7c21bc5fa8bdcf6426ab0578"'
assert_contains "${accel_proxy}" 'value: "registry-1.docker.io,ghcr.io,public.ecr.aws"'
assert_contains "${accel_proxy}" $'OCI_ACCELERATOR_CACHE_MAX_FILLS\n              value: "32"'
assert_contains "${accel_proxy}" $'- name: cache\n          emptyDir:\n            sizeLimit: 20Gi'
assert_contains "${accel_proxy}" $'OCI_ACCELERATOR_CACHE_MAX_BYTES\n              value: "19327352832"'
assert_contains "${accel_proxy}" $'replicas: 1\n  serviceName: test-buildkite-operator-oci-accelerator-peers\n  podManagementPolicy: Parallel'
assert_contains "${accel_proxy}" 'whenUnsatisfiable: ScheduleAnyway'
assert_contains "${accel_proxy}" $'requests:\n              cpu: 500m\n              ephemeral-storage: 20Gi\n              memory: 512Mi'
# A request set in resources is kept, and limits are untouched.
accel_storage=$(document "$(render "${accel_args[@]}" --set-string runnerPools.linux.runtime=kata \
	--set-string ociAccelerator.cache.size=8Gi --set ociAccelerator.cache.maxBytes=7516192768 \
	--set-string ociAccelerator.resources.requests.ephemeral-storage=12Gi)" StatefulSet test-buildkite-operator-oci-accelerator)
assert_contains "${accel_storage}" "sizeLimit: 8Gi"
assert_contains "${accel_storage}" "ephemeral-storage: 12Gi"
assert_contains "${accel_storage}" $'limits:\n              memory: 2Gi'
assert_contains "${accel_proxy}" $'path: ca.key\n'
assert_contains "$(document "${accel}" NetworkPolicy test-buildkite-operator-oci-accelerator)" "app.kubernetes.io/component: runner"
# Remote metrics are opt-in, with collector access separate from the listener.
assert_contains "${accel_proxy}" $'OCI_ACCELERATOR_METRICS_LISTEN\n              value: 127.0.0.1:9090'
if [[ "${accel_proxy}" == *"OCI_ACCELERATOR_METRICS_ALLOW_REMOTE"* || "${accel_proxy}" == *"containerPort: 9090"* ]]; then
	echo "Remote metrics were exposed by default" >&2
	exit 1
fi
metrics_args=(
	"${accel_args[@]}"
	--set-string runnerPools.linux.runtime=dind
	--values "${CHART_DIR}/examples/peering/values.yaml"
	--set-string agentToken.existingSecret.name=
	--set-string registryCredentials.auths[0].registry=ghcr.io
	--set-string registryCredentials.auths[0].username=user
	--set-string registryCredentials.auths[0].password=token
	--set-string ociAccelerator.podAnnotations.checksum/registry-credentials=not-the-checksum
)
remote_metrics=$(render "${metrics_args[@]}")
metrics_proxy=$(document "${remote_metrics}" StatefulSet test-buildkite-operator-oci-accelerator)
metrics_policy=$(document "${remote_metrics}" NetworkPolicy test-buildkite-operator-oci-accelerator)
assert_contains "${metrics_proxy}" $'OCI_ACCELERATOR_METRICS_LISTEN\n              value: 0.0.0.0:9090'
assert_contains "${metrics_proxy}" $'OCI_ACCELERATOR_METRICS_ALLOW_REMOTE\n              value: "true"'
assert_contains "${metrics_proxy}" $'- name: metrics\n              containerPort: 9090'
assert_contains "${metrics_proxy}" 'http://127.0.0.1:9090/readyz'
assert_contains "${metrics_proxy}" 'http://127.0.0.1:9090/livez'
assert_contains "${metrics_proxy}" $'annotations:\n        ad.datadoghq.com/oci-accelerator.checks: |'
assert_contains "${metrics_proxy}" '"openmetrics_endpoint": "http://%%host%%:9090/metrics"'
assert_contains "${metrics_proxy}" 'checksum/registry-credentials:'
if [[ "${metrics_proxy}" == *"not-the-checksum"* ]]; then
	echo "Pod annotations overrode the managed registry-credentials checksum" >&2
	exit 1
fi
# Both selectors must stay in one peer, and collectors get only the metrics port.
assert_contains "${metrics_policy}" $'- from:\n        - namespaceSelector:\n            matchLabels:\n              kubernetes.io/metadata.name: datadog\n          podSelector:\n            matchLabels:\n              agent.datadoghq.com/component: agent\n      ports:\n        - port: metrics\n          protocol: TCP'
assert_contains "${metrics_policy}" $'app.kubernetes.io/component: runner\n      ports:\n        - port: proxy'
assert_contains "${metrics_policy}" $'app.kubernetes.io/component: oci-accelerator\n      ports:\n        - port: peer'
for service in test-buildkite-operator-oci-accelerator test-buildkite-operator-oci-accelerator-peers; do
	if [[ "$(document "${remote_metrics}" Service "${service}")" == *"metrics"* ]]; then
		echo "Metrics were exposed through a Service" >&2
		exit 1
	fi
done
closed_metrics=$(render "${metrics_args[@]}" --set ociAccelerator.metrics.remote=false)
assert_contains "$(document "${closed_metrics}" StatefulSet test-buildkite-operator-oci-accelerator)" \
	$'OCI_ACCELERATOR_METRICS_LISTEN\n              value: 127.0.0.1:9090'
empty_metrics=$(render "${metrics_args[@]}" --set-json 'ociAccelerator.networkPolicy.metricsFrom=[]')
assert_contains "$(document "${empty_metrics}" StatefulSet test-buildkite-operator-oci-accelerator)" \
	$'OCI_ACCELERATOR_METRICS_LISTEN\n              value: 0.0.0.0:9090'
for isolated in "${closed_metrics}" "${empty_metrics}"; do
	policy=$(document "${isolated}" NetworkPolicy test-buildkite-operator-oci-accelerator)
	if [[ "${policy}" == *"port: metrics"* || "${policy}" == *"datadog"* ]]; then
		echo "Metrics ingress rendered without both remote metrics and sources" >&2
		exit 1
	fi
done
unrestricted_metrics=$(render "${metrics_args[@]}" --set ociAccelerator.networkPolicy.enabled=false)
[[ $(count_kind "${unrestricted_metrics}" NetworkPolicy) -eq 0 ]] || { echo "Metrics created a disabled NetworkPolicy" >&2; exit 1; }
assert_contains "$(document "${unrestricted_metrics}" StatefulSet test-buildkite-operator-oci-accelerator)" \
	$'OCI_ACCELERATOR_METRICS_LISTEN\n              value: 0.0.0.0:9090'
assert_fails "'/ociAccelerator/metrics/remote': got string, want boolean" "${accel_args[@]}" --set-string ociAccelerator.metrics.remote=yes
assert_fails "'/ociAccelerator/podAnnotations/test': got boolean, want string" "${accel_args[@]}" --set ociAccelerator.podAnnotations.test=true
assert_fails "'/ociAccelerator/networkPolicy/metricsFrom': got object, want array" "${accel_args[@]}" --set-json 'ociAccelerator.networkPolicy.metricsFrom={}'
# Peering keeps the runner endpoint but gives each replica its own stable address.
peering=$(render "${accel_args[@]}" --set-string runnerPools.linux.runtime=dind \
	--set ociAccelerator.peering.enabled=true --set ociAccelerator.replicas=3)
peer_proxy=$(document "${peering}" StatefulSet test-buildkite-operator-oci-accelerator)
assert_contains "${peer_proxy}" $'replicas: 3\n  serviceName: test-buildkite-operator-oci-accelerator-peers\n  podManagementPolicy: Parallel'
assert_contains "${peer_proxy}" $'OCI_ACCELERATOR_PEER_LISTEN\n              value: 0.0.0.0:5130'
assert_contains "${peer_proxy}" 'value: "$(POD_NAME).test-buildkite-operator-oci-accelerator-peers.buildkite-runners.svc:5130"'
assert_contains "${peer_proxy}" 'fieldPath: metadata.name'
assert_contains "${peer_proxy}" 'value: "test-buildkite-operator-oci-accelerator-0.test-buildkite-operator-oci-accelerator-peers.buildkite-runners.svc:5130,test-buildkite-operator-oci-accelerator-1.test-buildkite-operator-oci-accelerator-peers.buildkite-runners.svc:5130,test-buildkite-operator-oci-accelerator-2.test-buildkite-operator-oci-accelerator-peers.buildkite-runners.svc:5130"'
assert_contains "${peer_proxy}" $'OCI_ACCELERATOR_PEER_STATE_DIR\n              value: /run/oci-accelerator/private/peers'
assert_contains "${peer_proxy}" $'- name: peer\n              containerPort: 5130'
assert_contains "${peer_proxy}" 'automountServiceAccountToken: false'
assert_contains "${peer_proxy}" 'whenUnsatisfiable: ScheduleAnyway'
peer_service=$(document "${peering}" Service test-buildkite-operator-oci-accelerator-peers)
assert_contains "${peer_service}" 'clusterIP: None'
assert_contains "${peer_service}" 'publishNotReadyAddresses: true'
assert_contains "${peer_service}" $'- name: peer\n      port: 5130\n      targetPort: peer'
assert_contains "$(document "${peering}" Deployment test-linux)" '- --https-proxy=http://test-buildkite-operator-oci-accelerator.buildkite-runners.svc:5128'
peer_policy=$(document "${peering}" NetworkPolicy test-buildkite-operator-oci-accelerator)
assert_contains "${peer_policy}" $'app.kubernetes.io/component: runner\n      ports:\n        - port: proxy'
assert_contains "${peer_policy}" $'app.kubernetes.io/component: oci-accelerator\n      ports:\n        - port: peer'
if [[ -n "$(document "${peering}" Deployment test-buildkite-operator-oci-accelerator)" || "${peer_proxy}" == *"volumeClaimTemplates"* || "${accel_proxy}" == *"OCI_ACCELERATOR_PEER_"* ]]; then
	echo "Peering rendered the wrong workload, persistent storage, or leaked into default mode" >&2
	exit 1
fi
# Independent replicas use the same Services, without peer listeners or ingress.
independent=$(render "${accel_args[@]}" --set-string runnerPools.linux.runtime=dind --set ociAccelerator.replicas=2)
assert_contains "$(document "${independent}" StatefulSet test-buildkite-operator-oci-accelerator)" \
	$'replicas: 2\n  serviceName: test-buildkite-operator-oci-accelerator-peers'
assert_contains "$(document "${independent}" Service test-buildkite-operator-oci-accelerator)" 'type: ClusterIP'
independent_headless=$(document "${independent}" Service test-buildkite-operator-oci-accelerator-peers)
assert_contains "${independent_headless}" 'clusterIP: None'
assert_contains "${independent_headless}" 'targetPort: proxy'
if [[ "${independent}" == *"OCI_ACCELERATOR_PEER_"* || "${independent_headless}" == *"name: peer"* || "$(document "${independent}" NetworkPolicy test-buildkite-operator-oci-accelerator)" == *"port: peer"* ]]; then
	echo "Peering was enabled for independent replicas" >&2
	exit 1
fi
assert_fails "'/ociAccelerator/replicas': minimum:" "${accel_args[@]}" --set ociAccelerator.replicas=0
assert_fails "'/ociAccelerator/replicas': maximum:" "${accel_args[@]}" --set ociAccelerator.replicas=1025
accel_dind=$(document "$(render "${accel_args[@]}" --set-string runnerPools.linux.runtime=dind)" Deployment test-linux)
assert_contains "${accel_dind}" "- --https-proxy=http://test-buildkite-operator-oci-accelerator.buildkite-runners.svc:5128"
assert_contains "${accel_dind}" $'- name: SSL_CERT_DIR\n              value: /etc/ssl/certs:/etc/ssl/oci-accelerator-certs'
assert_contains "${accel_dind}" "${ca_cert_volume}"
if [[ "${accel_dind}" == *'"oci-ca"'* || "${accel_dind}" == *'"ca.key"'* ]]; then
	echo "dind runner Pods referenced the accelerator CA Secret" >&2
	exit 1
fi
no_policy=$(render "${accel_args[@]}" --set-string runnerPools.linux.runtime=kata --set ociAccelerator.networkPolicy.enabled=false)
[[ $(count_kind "${no_policy}" NetworkPolicy) -eq 0 ]] || { echo "NetworkPolicy rendered while disabled" >&2; exit 1; }
# Entries without a Docker daemon or that opt out pull directly, and with no
# entry using it the accelerator is not installed.
accel_opt_out=$("${HELM}" template test "${CHART_DIR}" "${KEDA_API_VERSIONS[@]}" "${accel_args[@]}" \
	--set-string runnerPools.std.queue=std --set runnerPools.std.maxReplicas=1 \
	--set-string runnerPools.kata.queue=kata --set-string runnerPools.kata.runtime=kata --set runnerPools.kata.maxReplicas=1 \
	--set runnerPools.kata.docker.ociAccelerator=false)
if [[ "${accel_opt_out}" == *"oci-accelerator"* || "${accel_opt_out}" == *"https-proxy"* ]]; then
	echo "The accelerator rendered with no entry using it" >&2
	exit 1
fi
# With an existing CA Secret, hook Jobs read it but never create or delete it.
[[ $(count_kind "${accel}" Job) -eq 2 ]] || { echo "Expected two CA hook Jobs with an existing CA Secret" >&2; exit 1; }
existing_create=$(document "${accel}" Job test-buildkite-operator-oci-accelerator-ca-create)
assert_contains "${existing_create}" $'SECRET_NAME\n              value: "oci-ca"'
assert_contains "${existing_create}" $'CONFIGMAP_NAME\n              value: "test-buildkite-operator-oci-accelerator-ca-cert"'
existing_delete=$(document "${accel}" Job test-buildkite-operator-oci-accelerator-ca-delete)
assert_contains "${existing_delete}" $'CONFIGMAP_NAME\n              value: "test-buildkite-operator-oci-accelerator-ca-cert"'
if [[ "${existing_create}" == *"init-ca"* || "${existing_delete}" == *"SECRET_NAME"* ]]; then
	echo "CA hook Jobs would generate or delete an existing CA Secret" >&2
	exit 1
fi
existing_role=$(document "${accel}" Role test-buildkite-operator-oci-accelerator-ca-hook)
assert_contains "${existing_role}" $'resourceNames: ["oci-ca"]\n    verbs: ["get"]'
if [[ "${existing_role}" == *'resources: ["secrets"]'$'\n    verbs:'* ]]; then
	echo "CA hook Role could create Secrets with an existing CA Secret" >&2
	exit 1
fi
if [[ "${accel}" == *"oci-accelerator-ca\""* ]]; then
	echo "Generated CA Secret referenced with an existing CA Secret" >&2
	exit 1
fi
# The accelerator loads the CA only from the Secret, so it never generates its own:
# an existing CA directory stops it from initializing one.
assert_contains "${accel_proxy}" "cp /ca-source/ca.crt /ca-source/ca.key /run/oci-accelerator/private/ca/"
assert_contains "${accel_proxy}" $'- name: ca-source\n          secret:\n            secretName: "oci-ca"'
assert_contains "${accel_proxy}" $'OCI_ACCELERATOR_CA_DIR\n              value: /run/oci-accelerator/private/ca'

# Without an existing Secret, hook Jobs generate the CA with init-ca before
# install and upgrade, and delete its Secret and ConfigMap after uninstall.
generated=$(render --set-string agentToken.value="${TOKEN}" --set ociAccelerator.enabled=true \
	--set-string runnerPools.linux.runtime=dind)
generated_secret="test-buildkite-operator-oci-accelerator-ca"
assert_contains "$(document "${generated}" StatefulSet test-buildkite-operator-oci-accelerator)" "secretName: \"${generated_secret}\""
generated_runner=$(document "${generated}" Deployment test-linux)
assert_contains "${generated_runner}" "${ca_cert_volume}"
if [[ "${generated_runner}" == *"${generated_secret}\""* ]]; then
	echo "Runner Pods referenced the generated CA Secret" >&2
	exit 1
fi
[[ $(count_kind "${generated}" Job) -eq 2 ]] || { echo "Expected two CA hook Jobs" >&2; exit 1; }
ca_create=$(document "${generated}" Job test-buildkite-operator-oci-accelerator-ca-create)
assert_contains "${ca_create}" "helm.sh/hook: pre-install,pre-upgrade"
assert_contains "${ca_create}" "oci-accelerator init-ca --dir /work/state/ca"
assert_contains "${ca_create}" 'image: "buildkite/oci-accelerator:v0.5.0@sha256:c671b75f349cf625fdd7555c632f17782d6b98ed7c21bc5fa8bdcf6426ab0578"'
assert_contains "${ca_create}" $'SECRET_NAME\n              value: "'"${generated_secret}"'"'
ca_delete=$(document "${generated}" Job test-buildkite-operator-oci-accelerator-ca-delete)
assert_contains "${ca_delete}" "helm.sh/hook: post-delete"
assert_contains "${ca_delete}" '"/opt/oci-accelerator-ca/oci_accelerator_ca.py", "delete"'
assert_contains "${ca_delete}" $'SECRET_NAME\n              value: "'"${generated_secret}"'"'
if [[ "${ca_delete}" == *"init-ca"* ]]; then
	echo "CA delete Job generated a CA" >&2
	exit 1
fi
ca_role=$(document "${generated}" Role test-buildkite-operator-oci-accelerator-ca-hook)
assert_contains "${ca_role}" "helm.sh/hook: pre-install,pre-upgrade,post-delete"
assert_contains "${ca_role}" $'resourceNames: ["'"${generated_secret}"$'"]\n    verbs: ["get", "delete"]'
assert_contains "${ca_role}" $'resourceNames: ["test-buildkite-operator-oci-accelerator-ca-cert"]\n    verbs: ["get", "patch", "delete"]'
for kind in ServiceAccount RoleBinding ConfigMap; do
	assert_contains "$(document "${generated}" "${kind}" test-buildkite-operator-oci-accelerator-ca-hook)" \
		"helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded"
done
if [[ $(count_kind "${generated}" Secret) -ne 1 || "$(document "${generated}" Secret "${generated_secret}")" != "" ]]; then
	echo "The chart rendered the CA Secret itself" >&2
	exit 1
fi
if [[ "${accel_opt_out}" == *"ca-create"* ]]; then
	echo "CA hook Jobs rendered with no entry using the accelerator" >&2
	exit 1
fi
assert_fails "ociAccelerator.noProxy must not include ghcr.io:443" \
	--set-string runnerPools.linux.queue=linux --set runnerPools.linux.maxReplicas=1 --set-string runnerPools.linux.runtime=kata \
	"${accel_args[@]}" --set ociAccelerator.noProxy='{ghcr.io:443}'
assert_fails "ociAccelerator.extraEnv.OCI_ACCELERATOR_LISTEN is managed by the chart" \
	--set-string runnerPools.linux.queue=linux --set runnerPools.linux.maxReplicas=1 --set-string runnerPools.linux.runtime=kata \
	"${accel_args[@]}" --set-string ociAccelerator.extraEnv.OCI_ACCELERATOR_LISTEN=0.0.0.0:1
assert_fails "ociAccelerator.extraEnv.OCI_ACCELERATOR_PEER_LISTEN is managed by the chart" \
	--set-string runnerPools.linux.queue=linux --set runnerPools.linux.maxReplicas=1 --set-string runnerPools.linux.runtime=kata \
	"${accel_args[@]}" --set-string ociAccelerator.extraEnv.OCI_ACCELERATOR_PEER_LISTEN=0.0.0.0:5130
assert_fails "does not match pattern" \
	--set-string runnerPools.linux.queue=linux --set runnerPools.linux.maxReplicas=1 \
	"${accel_args[@]}" --set ociAccelerator.registries='{https://ghcr.io}'
assert_fails "ociAccelerator.replicas must be at most 32 with ociAccelerator.peering.enabled, got 33" \
	--set-string runnerPools.linux.queue=linux --set runnerPools.linux.maxReplicas=1 --set-string runnerPools.linux.runtime=kata \
	"${accel_args[@]}" --set ociAccelerator.replicas=33 --set ociAccelerator.peering.enabled=true
"${HELM}" template test "${CHART_DIR}" "${KEDA_API_VERSIONS[@]}" \
	--set-string runnerPools.linux.queue=linux --set runnerPools.linux.maxReplicas=1 --set-string runnerPools.linux.runtime=kata \
	"${accel_args[@]}" --set ociAccelerator.replicas=32 --set ociAccelerator.peering.enabled=true >/dev/null
"${HELM}" template test "${CHART_DIR}" "${KEDA_API_VERSIONS[@]}" \
	--set-string runnerPools.linux.queue=linux --set runnerPools.linux.maxReplicas=1 --set-string runnerPools.linux.runtime=kata \
	"${accel_args[@]}" --set ociAccelerator.replicas=33 >/dev/null

# Docker runners always share a writable Docker client configuration for the
# Pod's lifetime; standard runners have none.
docker_config_mount=$'- name: docker-config\n              mountPath: /etc/buildkite-agent/docker'
docker_config_env=$'- name: DOCKER_CONFIG\n              value: /etc/buildkite-agent/docker'
assert_contains "${dind_runner}" "${docker_config_env}"
assert_contains "$(awk '/^        - name: agent$/,/^        - name: deletion-cost$/' <<<"${dind_runner}")" "${docker_config_mount}"
supervisor_container=$(awk '/^        - name: supervisor$/,/^        - name: deletion-cost$/' <<<"${ephemeral_dind_runner}")
assert_contains "${supervisor_container}" "${docker_config_env}"
assert_contains "${supervisor_container}" "${docker_config_mount}"
assert_contains "$(awk '/^        - name: dockerd$/,/^      containers:$/' <<<"${ephemeral_dind_runner}")" "${docker_config_mount}"
assert_contains "${ephemeral}" '--volume "$DOCKER_CONFIG:$DOCKER_CONFIG"'
for runner in "${dind_runner}" "${ephemeral_dind_runner}"; do
	assert_contains "${runner}" $'- name: docker-config\n          emptyDir:\n            sizeLimit: 16Mi'
	for unexpected in "imagePullSecrets:" "registry-credentials"; do
		if [[ "${runner}" == *"${unexpected}"* ]]; then
			echo "Runners without registry credentials rendered ${unexpected}" >&2
			exit 1
		fi
	done
done
if [[ "$(document "${direct}" Deployment test-linux)" == *"docker-config"* || "${direct}" == *"DOCKER_CONFIG"* ]]; then
	echo "Standard runners rendered a Docker client configuration" >&2
	exit 1
fi

# Docker runners put a copy of the agent binary in the workspace, which the
# Docker daemon shares, first on PATH, so plugins that mount it into job
# containers find a path the daemon can see. Standard runners don't.
agent_binary_copy='mkdir -p /buildkite/bin && cp /usr/local/bin/buildkite-agent /buildkite/bin/ && export PATH="/buildkite/bin:$PATH" && exec /usr/local/bin/buildkite-agent start'
assert_contains "$(awk '/^        - name: agent$/,/^        - name: deletion-cost$/' <<<"${dind_runner}")" "- ${agent_binary_copy}"
assert_contains "${ephemeral}" 'export PATH="/buildkite/bin:$PATH" &&'
if [[ "${direct}" == *"/buildkite/bin"* ]]; then
	echo "Standard runners rendered the agent binary copy" >&2
	exit 1
fi
# The plugins mount BUILDKITE_AGENT_BINARY_PATH whenever it is set, even when
# mount-buildkite-agent is off, so the chart must not set it.
if [[ "${dind_runner}${ephemeral}" == *"BUILDKITE_AGENT_BINARY_PATH"* ]]; then
	echo "Docker runners set BUILDKITE_AGENT_BINARY_PATH" >&2
	exit 1
fi

# Docker runners run jobs through the step-image script, so steps that set
# image: run in that image. The daemon runs the step containers, so it needs
# the Docker client configuration, and, with ephemeral agents, the script.
step_image_env=$'- name: BUILDKITE_BOOTSTRAP_SCRIPT_PATH\n              value: "/bin/sh /opt/step-image/step-image.sh"'
step_image_mount=$'- name: step-image\n              mountPath: /opt/step-image\n              readOnly: true'
step_image_volume=$'- name: step-image\n          configMap:\n            name: test-buildkite-operator-step-image'
dind_agent=$(awk '/^        - name: agent$/,/^        - name: deletion-cost$/' <<<"${dind_runner}")
dind_dockerd=$(awk '/^        - name: dockerd$/,/^      containers:$/' <<<"${dind_runner}")
assert_contains "${dind_agent}" "${step_image_env}"
assert_contains "${dind_agent}" $'- name: BUILDKITE_JOB_CONTEXT_DIR\n              value: /buildkite/job-context'
assert_contains "${dind_agent}" "${step_image_mount}"
assert_contains "${dind_dockerd}" "${docker_config_mount}"
assert_contains "${dind_runner}" "${step_image_volume}"
assert_contains "${dind_runner}" "checksum/step-image:"
assert_contains "$(document "${dind}" ConfigMap test-buildkite-operator-step-image)" '"$BUILDKITE_IMAGE" bootstrap >/dev/null'
assert_contains "${supervisor_container}" $'- name: STEP_IMAGE_SCRIPT\n              value: /opt/step-image/step-image.sh'
assert_contains "$(awk '/^        - name: dockerd$/,/^      containers:$/' <<<"${ephemeral_dind_runner}")" "${step_image_mount}"
assert_contains "${ephemeral_dind_runner}" "${step_image_volume}"
if [[ "${supervisor_container}" == *"- name: step-image"* ]]; then
	echo "The supervisor mounted the step-image script, which only the Docker daemon needs" >&2
	exit 1
fi
# Defaults reach both direct agents and supervisors for every Docker runtime.
for runtime in dind kata sysbox; do
	for ephemeral in false true; do
		with_default=$(render --set-string agentToken.value="${TOKEN}" \
			--set-string runnerPools.linux.runtime="${runtime}" --set runnerPools.linux.ephemeralAgent="${ephemeral}" \
			--set-string defaults.docker.defaultStepImage=example/default:noble)
		assert_contains "$(document "${with_default}" Deployment test-linux)" \
			$'- name: DEFAULT_STEP_IMAGE\n              value: "example/default:noble"'
	done
done
queue_image_args=(--set-string agentToken.value="${TOKEN}" --set-string runnerPools.linux.runtime=dind \
	--set-string defaults.docker.defaultStepImage=example/default:noble)
overridden=$(render "${queue_image_args[@]}" --set-string runnerPools.linux.docker.defaultStepImage=example/queue:alpine)
assert_contains "$(document "${overridden}" Deployment test-linux)" \
	$'- name: DEFAULT_STEP_IMAGE\n              value: "example/queue:alpine"'
cleared=$(render "${queue_image_args[@]}" --set-string runnerPools.linux.docker.defaultStepImage=)
assert_contains "$(document "${cleared}" Deployment test-linux)" \
	$'- name: DEFAULT_STEP_IMAGE\n              value: ""'
assert_fails "defaultStepImage" --set-string agentToken.value="${TOKEN}" \
	--set defaults.docker.defaultStepImage=42
no_step_images=$(render --set-string agentToken.value="${TOKEN}" --set-string runnerPools.linux.runtime=dind \
	--set runnerPools.linux.docker.stepImages=false --set-string defaults.docker.defaultStepImage=example/default:noble)
no_step_images_ephemeral=$(render --set-string agentToken.value="${TOKEN}" --set-string runnerPools.linux.runtime=dind \
	--set runnerPools.linux.ephemeralAgent=true --set runnerPools.linux.docker.stepImages=false \
	--set-string defaults.docker.defaultStepImage=example/default:noble)
standard_with_default=$(render --set-string agentToken.value="${TOKEN}" \
	--set-string defaults.docker.defaultStepImage=example/default:noble)
for output in "${direct}" "${ephemeral_standard}" "${standard_with_default}" "${no_step_images}" "${no_step_images_ephemeral}"; do
	runner=$(document "${output}" Deployment test-linux)
	if [[ "${runner}" == *"step-image"* || "${runner}" == *"BUILDKITE_JOB_CONTEXT_DIR"* ||
		"${runner}" == *"DEFAULT_STEP_IMAGE"* ||
		"${output}" == *"name: test-buildkite-operator-step-image"* ]]; then
		echo "Standard runners, or Docker runners with stepImages false, rendered step images" >&2
		exit 1
	fi
done
if [[ "$(awk '/^        - name: dockerd$/,/^      containers:$/' <<<"${no_step_images}")" == *"docker-config"* ]]; then
	echo "A persistent Docker daemon without step images mounted the Docker client configuration" >&2
	exit 1
fi

# Registry credentials become one dockerconfigjson Secret, used to pull every
# Pod's images and copied into Docker runners' client configuration.
credential_args=(
	--set-string agentToken.value="${TOKEN}"
	--set-string 'registryCredentials.auths[0].registry=https://index.docker.io/v1/'
	--set-string 'registryCredentials.auths[0].username=hub-user'
	--set-string 'registryCredentials.auths[0].password=hub-token'
	--set-string 'registryCredentials.auths[1].registry=ghcr.io'
	--set-string 'registryCredentials.auths[1].username=gh-user'
	--set-string 'registryCredentials.auths[1].password=gh-token'
)
credentials=$("${HELM}" template test "${CHART_DIR}" --namespace buildkite-runners "${KEDA_API_VERSIONS[@]}" \
	"${credential_args[@]}" --set ociAccelerator.enabled=true \
	--set-string runnerPools.std.queue=std --set runnerPools.std.maxReplicas=1 \
	--set-string runnerPools.per.queue=per --set-string runnerPools.per.runtime=dind --set runnerPools.per.maxReplicas=1 \
	--set-string runnerPools.eph.queue=eph --set-string runnerPools.eph.runtime=sysbox --set runnerPools.eph.ephemeralAgent=true \
	--set runnerPools.eph.maxReplicas=1)
credentials_secret=$(document "${credentials}" Secret test-buildkite-operator-registry-credentials)
assert_contains "${credentials_secret}" "type: kubernetes.io/dockerconfigjson"
dockerconfigjson=$(sed -n 's/^  \.dockerconfigjson: //p' <<<"${credentials_secret}" | base64 --decode)
expected_config='{"auths":{"ghcr.io":{"auth":"'"$(printf 'gh-user:gh-token' | base64)"'","password":"gh-token","username":"gh-user"},"https://index.docker.io/v1/":{"auth":"'"$(printf 'hub-user:hub-token' | base64)"'","password":"hub-token","username":"hub-user"}}}'
[[ "${dockerconfigjson}" == "${expected_config}" ]] || {
	echo "Unexpected .dockerconfigjson: ${dockerconfigjson}" >&2
	exit 1
}
pull_secret=$'imagePullSecrets:\n        - name: "test-buildkite-operator-registry-credentials"'
for deployment in test-std test-per test-eph; do
	assert_contains "$(document "${credentials}" Deployment "${deployment}")" "${pull_secret}"
	assert_contains "$(document "${credentials}" Deployment "${deployment}")" "checksum/registry-credentials:"
done
credentials_proxy=$(document "${credentials}" StatefulSet test-buildkite-operator-oci-accelerator)
assert_contains "${credentials_proxy}" "${pull_secret}"
assert_contains "${credentials_proxy}" "checksum/registry-credentials:"
# Hooks run before the release's Secret exists on install and after it is
# deleted on uninstall, so they pull with a copy that exists only while they run.
hook_secret=$(document "${credentials}" Secret test-buildkite-operator-registry-credentials-hook)
assert_contains "${hook_secret}" "helm.sh/hook: pre-install,pre-upgrade,post-delete"
assert_contains "${hook_secret}" 'helm.sh/hook-weight: "-20"'
assert_contains "${hook_secret}" "helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded,hook-failed"
assert_contains "${hook_secret}" "type: kubernetes.io/dockerconfigjson"
[[ "$(sed -n 's/^  \.dockerconfigjson: //p' <<<"${hook_secret}" | base64 --decode)" == "${expected_config}" ]] || {
	echo "Hook registry credentials Secret differs from the release's" >&2
	exit 1
}
if [[ "${credentials_secret}" == *"helm.sh/hook"* ]]; then
	echo "The release's registry credentials Secret was rendered as a hook" >&2
	exit 1
fi
for job in create delete; do
	assert_contains "$(document "${credentials}" Job "test-buildkite-operator-oci-accelerator-ca-${job}")" \
		$'imagePullSecrets:\n        - name: "test-buildkite-operator-registry-credentials-hook"'
done
# Without hook Jobs, there is no hook copy.
if [[ "$(render "${credential_args[@]}" --set-string runnerPools.linux.runtime=dind)" == *"registry-credentials-hook"* ]]; then
	echo "Hook registry credentials Secret rendered without hook Jobs" >&2
	exit 1
fi
credentials_std=$(document "${credentials}" Deployment test-std)
if [[ "${credentials_std}" == *"docker-config"* || "${credentials_std}" == *"- name: registry-credentials"* ]]; then
	echo "Standard runners received Docker client credentials" >&2
	exit 1
fi
copy_command='command: ["cp", "/registry-credentials/config.json", "/etc/buildkite-agent/docker/config.json"]'
for deployment in test-per test-eph; do
	credentials_runner=$(document "${credentials}" Deployment "${deployment}")
	assert_contains "${credentials_runner}" $'initContainers:\n        # Seed docker-config with registryCredentials, leaving it writable for jobs.\n        - name: docker-config'
	assert_contains "${credentials_runner}" "${copy_command}"
	assert_contains "${credentials_runner}" $'secretName: "test-buildkite-operator-registry-credentials"\n            items:\n              - key: .dockerconfigjson\n                path: config.json'
done
rotated_credentials=$(render "${credential_args[@]}" --set-string 'registryCredentials.auths[1].password=rotated')
if [[ $(grep 'checksum/registry-credentials:' <<<"${credentials_std}") == $(grep 'checksum/registry-credentials:' <<<"${rotated_credentials}") ]]; then
	echo "Registry credential rotation did not change the Pod template" >&2
	exit 1
fi
existing_credentials=$(render --set-string agentToken.value="${TOKEN}" --set-string runnerPools.linux.runtime=kata \
	--set-string registryCredentials.existingSecret.name=hub-pull)
assert_contains "${existing_credentials}" $'imagePullSecrets:\n        - name: "hub-pull"'
assert_contains "${existing_credentials}" $'secretName: "hub-pull"\n            items:\n              - key: .dockerconfigjson'
assert_contains "${existing_credentials}" "${copy_command}"
if [[ "${existing_credentials}" == *"checksum/registry-credentials:"* || "${existing_credentials}" == *"kubernetes.io/dockerconfigjson"* ]]; then
	echo "Existing registry credentials Secret mode rendered a Secret or checksum" >&2
	exit 1
fi
# An existing Secret is created before install, so hooks use it directly.
existing_credentials_hooks=$(render --set-string agentToken.value="${TOKEN}" --set-string runnerPools.linux.runtime=dind \
	--set ociAccelerator.enabled=true --set-string registryCredentials.existingSecret.name=hub-pull)
assert_contains "$(document "${existing_credentials_hooks}" Job test-buildkite-operator-oci-accelerator-ca-create)" \
	$'imagePullSecrets:\n        - name: "hub-pull"'
if [[ "${existing_credentials_hooks}" == *"registry-credentials-hook"* || "${existing_credentials_hooks}" == *"kubernetes.io/dockerconfigjson"* ]]; then
	echo "Existing registry credentials Secret mode rendered a hook Secret" >&2
	exit 1
fi
assert_fails "set only one of registryCredentials.auths or registryCredentials.existingSecret.name" \
	--set-string runnerPools.linux.queue=linux --set runnerPools.linux.maxReplicas=1 \
	"${credential_args[@]}" --set-string registryCredentials.existingSecret.name=hub-pull
assert_fails "registryCredentials.auths lists registry ghcr.io more than once" \
	--set-string runnerPools.linux.queue=linux --set runnerPools.linux.maxReplicas=1 \
	"${credential_args[@]}" --set-string 'registryCredentials.auths[0].registry=ghcr.io'
assert_fails "missing property 'password'" \
	--set-string runnerPools.linux.queue=linux --set runnerPools.linux.maxReplicas=1 \
	--set-string agentToken.value="${TOKEN}" \
	--set-string 'registryCredentials.auths[0].registry=ghcr.io' \
	--set-string 'registryCredentials.auths[0].username=gh-user'

# Entry names that YAML would read as numbers or booleans stay strings, as
# Kubernetes label values must be.
numeric=$("${HELM}" template test "${CHART_DIR}" \
	"${KEDA_API_VERSIONS[@]}" \
	--set-string agentToken.value="${TOKEN}" \
	--set-string runnerPools.123.queue=linux \
	--set runnerPools.123.maxReplicas=1 \
	--set-string runnerPools.true.queue=build \
	--set runnerPools.true.maxReplicas=1)
[[ $(grep -c 'buildkite.com/runner-pool: "123"$' <<<"${numeric}") -eq 4 ]] || {
	echo "Numeric entry name was not quoted in every runner-pool label" >&2
	exit 1
}
[[ $(grep -c 'buildkite.com/runner-pool: "true"$' <<<"${numeric}") -eq 4 ]] || {
	echo "Boolean-like entry name was not quoted in every runner-pool label" >&2
	exit 1
}

# A later values file can override or remove a single runner pool.
values_dir=$(mktemp -d)
trap 'rm -rf "${values_dir}"' EXIT
cat >"${values_dir}/base.yaml" <<EOF
agentToken: {value: ${TOKEN}}
runnerPools:
  linux-kata: {queue: linux, runtime: kata, maxReplicas: 10}
  build-sysbox: {queue: build, runtime: sysbox, ephemeralAgent: true, maxReplicas: 4}
EOF
cat >"${values_dir}/override.yaml" <<EOF
runnerPools:
  linux-kata: {maxReplicas: 25, scaleDownStabilizationWindowSeconds: 300}
  build-sysbox: null
EOF
overridden=$("${HELM}" template test "${CHART_DIR}" \
	"${KEDA_API_VERSIONS[@]}" \
	-f "${values_dir}/base.yaml" \
	-f "${values_dir}/override.yaml")
assert_contains "${overridden}" "maxReplicaCount: 25"
assert_contains "${overridden}" $'scaleDown:\n          stabilizationWindowSeconds: 300\n'
assert_contains "${overridden}" "runtimeClassName: kata-qemu-runtime-rs" # Untouched settings are kept.
[[ $(count_kind "${overridden}" Deployment) -eq 1 ]] || { echo "Null entry was not removed" >&2; exit 1; }
if [[ "${overridden}" == *"name: test-buildkite-operator-ephemeral-agent"* ]]; then
	echo "Ephemeral agent ConfigMap rendered with no ephemeral runner pool" >&2
	exit 1
fi

# NOTES lists the runtime prerequisites only for runtimes a release uses.
# helm template does not render NOTES, so use a client-side dry-run install.
notes() {
	"${HELM}" install test "${CHART_DIR}" --dry-run=client \
		--set keda.validateInstallation=false \
		--set-string agentToken.value="${TOKEN}" \
		"$@" | sed -n '/^NOTES:$/,$p'
}
runtime_notes=$(notes -f "${values_dir}/base.yaml")
assert_contains "${runtime_notes}" "kata needs RuntimeClass kata-qemu-runtime-rs and nodes labelled and tainted experiments.buildkite.com/runtime=kata"
assert_contains "${runtime_notes}" "sysbox needs RuntimeClass sysbox-runc and nodes labelled and tainted experiments.buildkite.com/runtime=sysbox"
assert_contains "${runtime_notes}" '"RuntimeClass not found"'
assert_contains "${runtime_notes}" "build-sysbox: queue build, sysbox, ephemeral agents, 1-4 runners"
accel_notes=$(notes -f "${values_dir}/base.yaml" --set ociAccelerator.enabled=true \
	--set-string ociAccelerator.ca.existingSecret.name=oci-ca --set runnerPools.build-sysbox.docker.ociAccelerator=false)
assert_contains "${accel_notes}" "Docker daemons for linux-kata pull through OCI Accelerator"
assert_contains "${accel_notes}" "kubectl logs statefulset/test-buildkite-operator-oci-accelerator"
assert_contains "${accel_notes}" "use at least two replicas for availability during updates"
assert_contains "${accel_notes}" "Peering is disabled"
peer_notes=$(notes -f "${values_dir}/base.yaml" --set ociAccelerator.enabled=true \
	--set ociAccelerator.peering.enabled=true --set ociAccelerator.replicas=3)
assert_contains "${peer_notes}" "kubectl logs statefulset/test-buildkite-operator-oci-accelerator"
assert_contains "${peer_notes}" "Accelerator replicas: 3"
assert_contains "${peer_notes}" "Peers use stable DNS seeds"
assert_contains "${peer_notes}" "restart the accelerator StatefulSet"
unused_accel_notes=$(notes --set ociAccelerator.enabled=true --set-string runnerPools.linux.queue=linux --set runnerPools.linux.maxReplicas=1)
assert_contains "${unused_accel_notes}" "no dind, kata or sysbox runner pool uses it"
standard_notes=$(notes --set-string runnerPools.linux.queue=linux --set runnerPools.linux.maxReplicas=1)
assert_contains "${standard_notes}" "linux: queue linux, standard, persistent agents, 1-1 runners"
if [[ "${standard_notes}" == *"RuntimeClass"* || "${standard_notes}" == *"privileged"* ]]; then
	echo "NOTES listed runtime prerequisites for a standard-only release" >&2
	exit 1
fi
assert_contains "${runtime_notes}" 'kata runner Pods include a privileged Docker daemon, so the namespace must allow privileged Pods (Pod Security Admission level "privileged")'
dind_notes=$(notes --set-string runnerPools.docker.queue=docker --set runnerPools.docker.maxReplicas=1 --set-string runnerPools.docker.runtime=dind)
assert_contains "${dind_notes}" "docker: queue docker, dind, persistent agents"
assert_contains "${dind_notes}" "dind runner Pods include a privileged Docker daemon"
assert_contains "${dind_notes}" "WARNING: dind needs nothing installed"
assert_contains "${dind_notes}" "only run trusted jobs on dind runner pools"
if [[ "${dind_notes}" == *"RuntimeClass"* ]]; then
	echo "NOTES listed RuntimeClass prerequisites for a dind-only release" >&2
	exit 1
fi

# With no runner pools, nothing is rendered and neither a token nor KEDA is
# needed.
empty=$("${HELM}" template test "${CHART_DIR}")
if [[ "${empty}" == *"kind:"* ]]; then
	echo "Chart rendered resources with no runner pools configured" >&2
	exit 1
fi

assert_fails "runnerPools.linux.queue is required" \
	--set runnerPools.linux.maxReplicas=1 \
	--set-string agentToken.value="${TOKEN}"
assert_fails "runnerPools.linux.maxReplicas must be at least 1" \
	--set-string runnerPools.linux.queue=linux \
	--set-string agentToken.value="${TOKEN}"
assert_fails "agentToken.value or agentToken.existingSecret.name is required" \
	--set-string runnerPools.linux.queue=linux \
	--set runnerPools.linux.maxReplicas=1
assert_fails "runnerPools.linux.minReplicas must be less than or equal" \
	--set-string runnerPools.linux.queue=linux \
	--set runnerPools.linux.maxReplicas=1 \
	--set runnerPools.linux.minReplicas=2 \
	--set-string agentToken.value="${TOKEN}"
assert_fails "metricsToken.value or metricsToken.existingSecret.name is required" \
	--set-string runnerPools.linux.queue=linux \
	--set runnerPools.linux.maxReplicas=1 \
	--set-string agentToken.existingSecret.name=agent-token
assert_fails "additional properties 'enabled' not allowed" \
	--set-string runnerPools.linux.queue=linux \
	--set runnerPools.linux.maxReplicas=1 \
	--set deletionCost.enabled=false \
	--set-string agentToken.value="${TOKEN}"
assert_fails "does not match pattern" \
	--set-string runnerPools.linux.queue=linux \
	--set runnerPools.linux.maxReplicas=1 \
	--set-string deletionCost.image.digest=latest \
	--set-string agentToken.value="${TOKEN}"
assert_fails "value must be one of 'standard', 'dind', 'kata', 'sysbox'" \
	--set-string runnerPools.linux.queue=linux \
	--set runnerPools.linux.maxReplicas=1 \
	--set-string runnerPools.linux.runtime=gvisor \
	--set-string agentToken.value="${TOKEN}"
assert_fails "maximum: got 3,601, want 3,600" \
	--set-string runnerPools.linux.queue=linux \
	--set runnerPools.linux.maxReplicas=1 \
	--set runnerPools.linux.scaleDownStabilizationWindowSeconds=3601 \
	--set-string agentToken.value="${TOKEN}"
assert_fails "does not match pattern" \
	--set-string runnerPools.linux.queue=linux \
	--set runnerPools.linux.maxReplicas=1 \
	--set-string supervisor.image.digest=latest \
	--set-string agentToken.value="${TOKEN}"

for scope in defaults runnerPools.linux; do
	scaling_args=(--set-string runnerPools.linux.queue=linux --set runnerPools.linux.maxReplicas=4 \
		--set-string agentToken.value="${TOKEN}")
	assert_fails "scalingFormula" "${scaling_args[@]}" --set "${scope}.scalingFormula=42"
	assert_fails "scalingFormula" "${scaling_args[@]}" --set-string "${scope}.scalingFormula="
	assert_fails "scalingModifiers" "${scaling_args[@]}" --set-string "${scope}.scalingModifiers.target=2"
done
assert_fails "runnerPools.Linux_Pool: names must be lowercase" \
	--set-string runnerPools.Linux_Pool.queue=linux \
	--set runnerPools.Linux_Pool.maxReplicas=1 \
	--set-string agentToken.value="${TOKEN}"
assert_fails "must be at most 50 characters" \
	--set-string runnerPools.an-extremely-long-runner-pool-name-for-testing.queue=linux \
	--set runnerPools.an-extremely-long-runner-pool-name-for-testing.maxReplicas=1 \
	--set-string agentToken.value="${TOKEN}"
# Values from before the rename must fail rather than render no runner pools.
assert_fails "queues was renamed to runnerPools" \
	--set-string queues.linux.queue=linux \
	--set queues.linux.maxReplicas=1 \
	--set-string agentToken.value="${TOKEN}"
assert_fails "additional properties 'replicas' not allowed" \
	--set-string runnerPools.linux.queue=linux \
	--set runnerPools.linux.maxReplicas=1 \
	--set runnerPools.linux.replicas=3 \
	--set-string agentToken.value="${TOKEN}"

"${HELM}" lint "${CHART_DIR}" \
	--set keda.validateInstallation=false \
	--set-string runnerPools.linux.queue=linux \
	--set runnerPools.linux.maxReplicas=4 \
	--set-string agentToken.value="${TOKEN}"
