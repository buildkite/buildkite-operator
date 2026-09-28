#!/usr/bin/env bash

set -euo pipefail

HELM="${HELM:-helm}"
CHART_DIR="${HELM_CHART_DIR:-charts/buildkite-operator}"
TOKEN="chart-test-agent-token"

render() {
	"${HELM}" template test "${CHART_DIR}" \
		--namespace buildkite-runners \
		--set-string runnerPool.queue=linux \
		--set runnerPool.maxRunners=4 \
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
	if output=$("${HELM}" template test "${CHART_DIR}" "$@" 2>&1); then
		echo "Expected Helm rendering to fail" >&2
		exit 1
	fi
	assert_contains "${output}" "${expected}"
}

direct=$(render --set-string agentToken.value="${TOKEN}")
assert_contains "${direct}" "# Source: buildkite-operator/templates/runnerpool.yaml"
assert_contains "${direct}" "queue: \"linux\""
assert_contains "${direct}" "runtime: \"standard\""
assert_contains "${direct}" "maxRunners: 4"
assert_contains "${direct}" "minIdleRunners: 1"
assert_contains "${direct}" "kind: Secret"
assert_contains "${direct}" "${TOKEN}"

crds=$("${HELM}" show crds "${CHART_DIR}")
assert_contains "${crds}" "name: runnerpools.buildkite.com"

existing=$(render --set-string agentToken.existingSecret.name=managed-token)
assert_contains "${existing}" 'name: "managed-token"'
if [[ "${existing}" == *"kind: Secret"* ]]; then
	echo "Existing Secret mode rendered an agent token Secret" >&2
	exit 1
fi

kata=$(render --set-string agentToken.value="${TOKEN}" --set-string runnerPool.runtime=kata)
assert_contains "${kata}" 'runtime: "kata"'

sysbox=$(render --set-string agentToken.value="${TOKEN}" --set-string runnerPool.runtime=sysbox)
assert_contains "${sysbox}" 'runtime: "sysbox"'

operator_only=$("${HELM}" template test "${CHART_DIR}" --set runnerPool.enabled=false)
if [[ "${operator_only}" == *"# Source: buildkite-operator/templates/runnerpool.yaml"* || "${operator_only}" == *"kind: Secret"* ]]; then
	echo "Operator-only mode rendered runner resources" >&2
	exit 1
fi

assert_fails "runnerPool.queue is required" \
	--set runnerPool.maxRunners=1 \
	--set-string agentToken.value="${TOKEN}"
assert_fails "runnerPool.maxRunners must be at least 1" \
	--set-string runnerPool.queue=linux \
	--set-string agentToken.value="${TOKEN}"
assert_fails "agentToken.value or agentToken.existingSecret.name is required" \
	--set-string runnerPool.queue=linux \
	--set runnerPool.maxRunners=1
assert_fails "runnerPool.minIdleRunners must be less than or equal" \
	--set-string runnerPool.queue=linux \
	--set runnerPool.maxRunners=1 \
	--set runnerPool.minIdleRunners=2 \
	--set-string agentToken.value="${TOKEN}"
assert_fails "value must be one of 'standard', 'kata', 'sysbox'" \
	--set-string runnerPool.queue=linux \
	--set runnerPool.maxRunners=1 \
	--set-string runnerPool.runtime=gvisor \
	--set-string agentToken.value="${TOKEN}"

"${HELM}" lint "${CHART_DIR}" \
	--set-string runnerPool.queue=linux \
	--set runnerPool.maxRunners=4 \
	--set-string agentToken.value="${TOKEN}"
