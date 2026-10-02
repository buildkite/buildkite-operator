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
		--set-string queues.linux.queue=linux \
		--set queues.linux.maxReplicas=4 \
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

if missing_keda=$("${HELM}" template test "${CHART_DIR}" \
	--set-string queues.linux.queue=linux \
	--set queues.linux.maxReplicas=4 \
	--set-string agentToken.value="${TOKEN}" 2>&1); then
	echo "Expected rendering without KEDA APIs to fail" >&2
	exit 1
fi
assert_contains "${missing_keda}" "KEDA is required"

if missing_auth=$("${HELM}" template test "${CHART_DIR}" \
	--api-versions keda.sh/v1alpha1/ScaledObject \
	--set-string queues.linux.queue=linux \
	--set queues.linux.maxReplicas=4 \
	--set-string agentToken.value="${TOKEN}" 2>&1); then
	echo "Expected rendering without the TriggerAuthentication API to fail" >&2
	exit 1
fi
assert_contains "${missing_auth}" "keda.sh/v1alpha1/TriggerAuthentication API is not available"

direct=$(render --set-string agentToken.value="${TOKEN}")
assert_contains "${direct}" "# Source: buildkite-operator/templates/runners.yaml"
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
assert_contains "${direct}" 'buildkite.com/runner-set: "linux"'
assert_contains "${direct}" "- name: deletion-cost"
assert_contains "${direct}" "kind: Role"
assert_contains "${direct}" 'verbs: ["patch"]'
assert_contains "${direct}" "def agent_busy():"
assert_contains "${direct}" 'image: "python:3.12.14-alpine3.24@sha256:4c47124a8391cb7a9f571164147d154777cf012a4ece5f86097130d7a4478111"'
[[ $(grep -c 'mountPath: /var/run/secrets/kubernetes.io/serviceaccount' <<<"${direct}") -eq 1 ]] || {
	echo "Kubernetes API token was mounted into more than the deletion-cost sidecar" >&2
	exit 1
}
assert_contains "${direct}" 'value: "queue=linux,runtime=standard"'
assert_contains "${direct}" "value: /buildkite/builds"
assert_contains "${direct}" "checksum/agent-token:"
rotated=$(render --set-string agentToken.value="${TOKEN}-rotated")
if [[ $(grep 'checksum/agent-token:' <<<"${direct}") == $(grep 'checksum/agent-token:' <<<"${rotated}") ]]; then
	echo "Agent token rotation did not change the Pod template" >&2
	exit 1
fi
assert_contains "${direct}" "minReplicaCount: 1"
assert_contains "${direct}" "maxReplicaCount: 4"
assert_contains "${direct}" "formula: scheduled + running"
assert_contains "${direct}" $'scaleDown:\n          stabilizationWindowSeconds: 60\n'
assert_contains "${direct}" 'valueLocation: "jobs.queues.linux.scheduled"'
assert_contains "${direct}" "token: \"${TOKEN}\""
assert_contains "${direct}" "authorization: \"Token ${TOKEN}\""
if [[ "${direct}" == *$'\n  replicas:'* ]]; then
	echo "Deployment rendered spec.replicas even though KEDA owns scaling" >&2
	exit 1
fi

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

kata=$(render --set-string agentToken.value="${TOKEN}" --set-string queues.linux.runtime=kata)
assert_contains "${kata}" "runtimeClassName: kata-qemu-runtime-rs"
assert_contains "${kata}" "privileged: true"
assert_contains "${kata}" 'value: "queue=linux,runtime=kata"'
assert_contains "${kata}" "- name: deletion-cost-code"
assert_contains "${kata}" "- name: docker-data"
assert_contains "${kata}" 'cluster-autoscaler.kubernetes.io/safe-to-evict: "false"'

sysbox=$(render --set-string agentToken.value="${TOKEN}" --set-string queues.linux.runtime=sysbox)
assert_contains "${sysbox}" "runtimeClassName: sysbox-runc"
assert_contains "${sysbox}" "hostUsers: false"
assert_contains "${sysbox}" "- --storage-driver=overlay2"
assert_contains "${sysbox}" 'value: "queue=linux,runtime=sysbox"'
if [[ "${sysbox}" == *"name: supervisor"* ]]; then
	echo "Long-lived runners rendered the single-use supervisor" >&2
	exit 1
fi

single_use=$(render --set-string agentToken.value="${TOKEN}" --set-string queues.linux.runtime=sysbox --set queues.linux.singleUse=true)
assert_contains "${single_use}" "- name: supervisor"
assert_contains "${single_use}" 'image: "docker:29.7.2-cli@sha256:3f4743208d2338c934d7b8bcfbe1bb54c0b2355c510ad5e0f31c0c4a54bd704e"'
assert_contains "${single_use}" 'value: "buildkite/agent:4"'
assert_contains "${single_use}" "checksum/supervisor:"
assert_contains "${single_use}" "start --disconnect-after-job"
assert_contains "${single_use}" "- name: dockerd"
if [[ "${single_use}" == *"- name: agent"* ]]; then
	echo "Single-use runners also rendered a long-lived agent container" >&2
	exit 1
fi
single_use_kata=$(render --set-string agentToken.value="${TOKEN}" --set-string queues.linux.runtime=kata --set queues.linux.singleUse=true)
assert_contains "${single_use_kata}" "runtimeClassName: kata-qemu-runtime-rs"
assert_contains "${single_use_kata}" "- name: supervisor"

# Queue entries inherit defaults and override any field. Shared resources are
# rendered once; each entry gets its own Deployment and ScaledObject.
multi=$("${HELM}" template test "${CHART_DIR}" \
	--namespace buildkite-runners \
	"${KEDA_API_VERSIONS[@]}" \
	--set-string agentToken.value="${TOKEN}" \
	--set defaults.minReplicas=2 \
	--set defaults.scaleDownStabilizationWindowSeconds=120 \
	--set-string queues.linux-kata.queue=linux \
	--set-string queues.linux-kata.runtime=kata \
	--set queues.linux-kata.maxReplicas=10 \
	--set-string queues.build-sysbox.queue=build \
	--set-string queues.build-sysbox.runtime=sysbox \
	--set queues.build-sysbox.singleUse=true \
	--set queues.build-sysbox.minReplicas=0 \
	--set queues.build-sysbox.maxReplicas=4 \
	--set queues.build-sysbox.scaleDownStabilizationWindowSeconds=0 \
	--set-string queues.build-sysbox.docker.resources.limits.memory=16Gi)
count_kind() { grep -c "^kind: $2\$" <<<"$1" || true; }
for kind in Secret TriggerAuthentication ServiceAccount Role RoleBinding; do
	[[ $(count_kind "${multi}" "${kind}") -eq 1 ]] || { echo "Expected one shared ${kind}" >&2; exit 1; }
done
[[ $(count_kind "${multi}" Deployment) -eq 2 && $(count_kind "${multi}" ScaledObject) -eq 2 ]] || {
	echo "Expected one Deployment and ScaledObject per queue entry" >&2
	exit 1
}
# Print the rendered document of the given kind and name.
document() {
	awk -v kind="$2" -v name="$3" '
		/^---$/ { if (doc ~ "\nkind: " kind "\n" && doc ~ "\n  name: " name "\n") printf "%s", doc; doc = "\n"; next }
		{ doc = doc $0 "\n" }
		END { if (doc ~ "\nkind: " kind "\n" && doc ~ "\n  name: " name "\n") printf "%s", doc }' <<<"$1"
}
kata_runner=$(document "${multi}" Deployment test-linux-kata)
sysbox_runner=$(document "${multi}" Deployment test-build-sysbox)
assert_contains "${kata_runner}" "runtimeClassName: kata-qemu-runtime-rs"
assert_contains "${kata_runner}" "- name: agent"
assert_contains "${kata_runner}" 'value: "queue=linux,runtime=kata"'
assert_contains "${kata_runner}" 'buildkite.com/runner-set: "linux-kata"'
assert_contains "${kata_runner}" "memory: 8Gi"
assert_contains "${sysbox_runner}" "runtimeClassName: sysbox-runc"
assert_contains "${sysbox_runner}" "- name: supervisor"
assert_contains "${sysbox_runner}" 'value: "queue=build,runtime=sysbox"'
assert_contains "${sysbox_runner}" 'buildkite.com/runner-set: "build-sysbox"'
assert_contains "${sysbox_runner}" "memory: 16Gi"
assert_contains "${sysbox_runner}" 'cpu: "4"' # Inherited alongside the memory override.
# Each Deployment must select only its own entry's Pods; otherwise a release's
# Deployments would adopt each other's runners.
for entry in linux-kata build-sysbox; do
	selector=$(document "${multi}" Deployment "test-${entry}" | awk '/^  selector:$/ { found = 1; next } found && /^  [^ ]/ { found = 0 } found { print }')
	assert_contains "${selector}" "buildkite.com/runner-set: \"${entry}\""
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
assert_contains "${multi}" "name: test-buildkite-operator-supervisor"

# Entry names that YAML would read as numbers or booleans stay strings, as
# Kubernetes label values must be.
numeric=$("${HELM}" template test "${CHART_DIR}" \
	"${KEDA_API_VERSIONS[@]}" \
	--set-string agentToken.value="${TOKEN}" \
	--set-string queues.123.queue=linux \
	--set queues.123.maxReplicas=1 \
	--set-string queues.true.queue=build \
	--set queues.true.maxReplicas=1)
[[ $(grep -c 'buildkite.com/runner-set: "123"$' <<<"${numeric}") -eq 4 ]] || {
	echo "Numeric entry name was not quoted in every runner-set label" >&2
	exit 1
}
[[ $(grep -c 'buildkite.com/runner-set: "true"$' <<<"${numeric}") -eq 4 ]] || {
	echo "Boolean-like entry name was not quoted in every runner-set label" >&2
	exit 1
}

# A later values file can override or remove a single queue entry.
values_dir=$(mktemp -d)
trap 'rm -rf "${values_dir}"' EXIT
cat >"${values_dir}/base.yaml" <<EOF
agentToken: {value: ${TOKEN}}
queues:
  linux-kata: {queue: linux, runtime: kata, maxReplicas: 10}
  build-sysbox: {queue: build, runtime: sysbox, singleUse: true, maxReplicas: 4}
EOF
cat >"${values_dir}/override.yaml" <<EOF
queues:
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
if [[ "${overridden}" == *"name: test-buildkite-operator-supervisor"* ]]; then
	echo "Supervisor ConfigMap rendered with no single-use queue" >&2
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
standard_notes=$(notes --set-string queues.linux.queue=linux --set queues.linux.maxReplicas=1)
assert_contains "${standard_notes}" "linux: queue linux, standard"
if [[ "${standard_notes}" == *"RuntimeClass"* ]]; then
	echo "NOTES listed runtime prerequisites for a standard-only release" >&2
	exit 1
fi

# With no queues, nothing is rendered and neither a token nor KEDA is needed.
empty=$("${HELM}" template test "${CHART_DIR}")
if [[ "${empty}" == *"kind:"* ]]; then
	echo "Chart rendered resources with no queues configured" >&2
	exit 1
fi

assert_fails "queues.linux.queue is required" \
	--set queues.linux.maxReplicas=1 \
	--set-string agentToken.value="${TOKEN}"
assert_fails "queues.linux.maxReplicas must be at least 1" \
	--set-string queues.linux.queue=linux \
	--set-string agentToken.value="${TOKEN}"
assert_fails "agentToken.value or agentToken.existingSecret.name is required" \
	--set-string queues.linux.queue=linux \
	--set queues.linux.maxReplicas=1
assert_fails "queues.linux.minReplicas must be less than or equal" \
	--set-string queues.linux.queue=linux \
	--set queues.linux.maxReplicas=1 \
	--set queues.linux.minReplicas=2 \
	--set-string agentToken.value="${TOKEN}"
assert_fails "metricsToken.value or metricsToken.existingSecret.name is required" \
	--set-string queues.linux.queue=linux \
	--set queues.linux.maxReplicas=1 \
	--set-string agentToken.existingSecret.name=agent-token
assert_fails "additional properties 'enabled' not allowed" \
	--set-string queues.linux.queue=linux \
	--set queues.linux.maxReplicas=1 \
	--set deletionCost.enabled=false \
	--set-string agentToken.value="${TOKEN}"
assert_fails "does not match pattern" \
	--set-string queues.linux.queue=linux \
	--set queues.linux.maxReplicas=1 \
	--set-string deletionCost.image.digest=latest \
	--set-string agentToken.value="${TOKEN}"
assert_fails "value must be one of 'standard', 'kata', 'sysbox'" \
	--set-string queues.linux.queue=linux \
	--set queues.linux.maxReplicas=1 \
	--set-string queues.linux.runtime=gvisor \
	--set-string agentToken.value="${TOKEN}"
assert_fails "queues.linux.singleUse requires runtime kata or sysbox" \
	--set-string queues.linux.queue=linux \
	--set queues.linux.maxReplicas=1 \
	--set queues.linux.singleUse=true \
	--set-string agentToken.value="${TOKEN}"
assert_fails "maximum: got 3,601, want 3,600" \
	--set-string queues.linux.queue=linux \
	--set queues.linux.maxReplicas=1 \
	--set queues.linux.scaleDownStabilizationWindowSeconds=3601 \
	--set-string agentToken.value="${TOKEN}"
assert_fails "does not match pattern" \
	--set-string queues.linux.queue=linux \
	--set queues.linux.maxReplicas=1 \
	--set-string supervisor.image.digest=latest \
	--set-string agentToken.value="${TOKEN}"

assert_fails 'queues.a and queues.b both use Buildkite queue "linux"' \
	--set-string queues.a.queue=linux \
	--set queues.a.maxReplicas=1 \
	--set-string queues.b.queue=linux \
	--set queues.b.maxReplicas=1 \
	--set-string agentToken.value="${TOKEN}"
assert_fails "queues.Linux_Pool: names must be lowercase" \
	--set-string queues.Linux_Pool.queue=linux \
	--set queues.Linux_Pool.maxReplicas=1 \
	--set-string agentToken.value="${TOKEN}"
assert_fails "must be at most 50 characters" \
	--set-string queues.an-extremely-long-queue-entry-name-for-testing.queue=linux \
	--set queues.an-extremely-long-queue-entry-name-for-testing.maxReplicas=1 \
	--set-string agentToken.value="${TOKEN}"
assert_fails "queues.linux.singleUse requires runtime kata or sysbox" \
	--set defaults.singleUse=true \
	--set-string queues.linux.queue=linux \
	--set queues.linux.maxReplicas=1 \
	--set-string agentToken.value="${TOKEN}"
assert_fails "additional properties 'replicas' not allowed" \
	--set-string queues.linux.queue=linux \
	--set queues.linux.maxReplicas=1 \
	--set queues.linux.replicas=3 \
	--set-string agentToken.value="${TOKEN}"

"${HELM}" lint "${CHART_DIR}" \
	--set keda.validateInstallation=false \
	--set-string queues.linux.queue=linux \
	--set queues.linux.maxReplicas=4 \
	--set-string agentToken.value="${TOKEN}"
