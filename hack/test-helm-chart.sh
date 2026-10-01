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
		--set-string runners.queue=linux \
		--set runners.maxReplicas=4 \
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
	--set-string runners.queue=linux \
	--set runners.maxReplicas=4 \
	--set-string agentToken.value="${TOKEN}" 2>&1); then
	echo "Expected rendering without KEDA APIs to fail" >&2
	exit 1
fi
assert_contains "${missing_keda}" "KEDA is required"

if missing_auth=$("${HELM}" template test "${CHART_DIR}" \
	--api-versions keda.sh/v1alpha1/ScaledObject \
	--set-string runners.queue=linux \
	--set runners.maxReplicas=4 \
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
assert_contains "${direct}" "serviceAccountName: test-buildkite-operator-runners-deletion-cost"
assert_contains "${direct}" "- name: deletion-cost"
assert_contains "${direct}" "kind: Role"
assert_contains "${direct}" 'verbs: ["patch"]'
assert_contains "${direct}" "def deletion_cost():"
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

kata=$(render --set-string agentToken.value="${TOKEN}" --set-string runners.runtime=kata)
assert_contains "${kata}" "runtimeClassName: kata-qemu-runtime-rs"
assert_contains "${kata}" "privileged: true"
assert_contains "${kata}" 'value: "queue=linux,runtime=kata"'
assert_contains "${kata}" "- name: deletion-cost-code"
assert_contains "${kata}" "- name: docker-data"

sysbox=$(render --set-string agentToken.value="${TOKEN}" --set-string runners.runtime=sysbox)
assert_contains "${sysbox}" "runtimeClassName: sysbox-runc"
assert_contains "${sysbox}" "hostUsers: false"
assert_contains "${sysbox}" "- --storage-driver=overlay2"
assert_contains "${sysbox}" 'value: "queue=linux,runtime=sysbox"'
if [[ "${sysbox}" == *"name: supervisor"* ]]; then
	echo "Long-lived runners rendered the single-use supervisor" >&2
	exit 1
fi

single_use=$(render --set-string agentToken.value="${TOKEN}" --set-string runners.runtime=sysbox --set runners.singleUse=true)
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
single_use_kata=$(render --set-string agentToken.value="${TOKEN}" --set-string runners.runtime=kata --set runners.singleUse=true)
assert_contains "${single_use_kata}" "runtimeClassName: kata-qemu-runtime-rs"
assert_contains "${single_use_kata}" "- name: supervisor"

disabled=$("${HELM}" template test "${CHART_DIR}" --set runners.enabled=false)
if [[ "${disabled}" == *"kind: Deployment"* || "${disabled}" == *"kind: ScaledObject"* || "${disabled}" == *"kind: Secret"* || "${disabled}" == *"kind: Role"* ]]; then
	echo "Disabled runner mode rendered runner resources" >&2
	exit 1
fi

assert_fails "runners.queue is required" \
	--set runners.maxReplicas=1 \
	--set-string agentToken.value="${TOKEN}"
assert_fails "runners.maxReplicas must be at least 1" \
	--set-string runners.queue=linux \
	--set-string agentToken.value="${TOKEN}"
assert_fails "agentToken.value or agentToken.existingSecret.name is required" \
	--set-string runners.queue=linux \
	--set runners.maxReplicas=1
assert_fails "runners.minReplicas must be less than or equal" \
	--set-string runners.queue=linux \
	--set runners.maxReplicas=1 \
	--set runners.minReplicas=2 \
	--set-string agentToken.value="${TOKEN}"
assert_fails "metricsToken.value or metricsToken.existingSecret.name is required" \
	--set-string runners.queue=linux \
	--set runners.maxReplicas=1 \
	--set-string agentToken.existingSecret.name=agent-token
assert_fails "additional properties 'enabled' not allowed" \
	--set-string runners.queue=linux \
	--set runners.maxReplicas=1 \
	--set deletionCost.enabled=false \
	--set-string agentToken.value="${TOKEN}"
assert_fails "does not match pattern" \
	--set-string runners.queue=linux \
	--set runners.maxReplicas=1 \
	--set-string deletionCost.image.digest=latest \
	--set-string agentToken.value="${TOKEN}"
assert_fails "value must be one of 'standard', 'kata', 'sysbox'" \
	--set-string runners.queue=linux \
	--set runners.maxReplicas=1 \
	--set-string runners.runtime=gvisor \
	--set-string agentToken.value="${TOKEN}"
assert_fails "runners.singleUse requires runners.runtime kata or sysbox" \
	--set-string runners.queue=linux \
	--set runners.maxReplicas=1 \
	--set runners.singleUse=true \
	--set-string agentToken.value="${TOKEN}"
assert_fails "does not match pattern" \
	--set-string runners.queue=linux \
	--set runners.maxReplicas=1 \
	--set-string supervisor.image.digest=latest \
	--set-string agentToken.value="${TOKEN}"

"${HELM}" lint "${CHART_DIR}" \
	--set keda.validateInstallation=false \
	--set-string runners.queue=linux \
	--set runners.maxReplicas=4 \
	--set-string agentToken.value="${TOKEN}"
