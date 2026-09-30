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
[[ $(grep -c 'mountPath: /var/run/secrets/kubernetes.io/serviceaccount' <<<"${direct}") -eq 1 ]] || {
	echo "Kubernetes API token was mounted into more than the deletion-cost sidecar" >&2
	exit 1
}
assert_contains "${direct}" 'value: "queue=linux,runtime=standard"'
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

no_deletion_cost=$(render --set-string agentToken.value="${TOKEN}" --set deletionCost.enabled=false)
if [[ "${no_deletion_cost}" == *"deletion-cost"* || "${no_deletion_cost}" == *"kind: Role"* || "${no_deletion_cost}" == *"volumes:"* ]]; then
	echo "Disabled deletion cost rendered sidecar resources" >&2
	exit 1
fi

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
assert_fails "value must be one of 'standard', 'kata', 'sysbox'" \
	--set-string runners.queue=linux \
	--set runners.maxReplicas=1 \
	--set-string runners.runtime=gvisor \
	--set-string agentToken.value="${TOKEN}"

"${HELM}" lint "${CHART_DIR}" \
	--set keda.validateInstallation=false \
	--set-string runners.queue=linux \
	--set runners.maxReplicas=4 \
	--set-string agentToken.value="${TOKEN}"
