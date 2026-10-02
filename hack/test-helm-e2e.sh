#!/usr/bin/env bash

set -euo pipefail

HELM="${HELM:-helm}"
CHART_DIR="${HELM_CHART_DIR:-charts/buildkite-operator}"
: "${KUBECONFIG:?KUBECONFIG must identify the isolated test cluster}"
: "${KUBE_CONTEXT:?KUBE_CONTEXT must identify the isolated test context}"
: "${KIND_CLUSTER:?KIND_CLUSTER must identify the isolated test cluster}"
if [[ "${KUBE_CONTEXT}" != "kind-${KIND_CLUSTER}" ]]; then
	echo "KUBE_CONTEXT must match the isolated Kind cluster" >&2
	exit 1
fi
HELM_CLUSTER=("${HELM}" --kubeconfig "${KUBECONFIG}" --kube-context "${KUBE_CONTEXT}")
KUBECTL=(kubectl --kubeconfig "${KUBECONFIG}" --context "${KUBE_CONTEXT}")
NAMESPACE="buildkite-runners"
RELEASE="buildkite-runners"
# The first release serves two queues to verify entries stay independent.
RUNNERS="${RELEASE}-e2e"
OTHER_RUNNERS="${RELEASE}-e2e-other"
SECOND_NAMESPACE="buildkite-runners-two"
SECOND_RELEASE="buildkite-runners-two"
SECOND_RUNNERS="${SECOND_RELEASE}-e2e-secondary"
KEDA_NAMESPACE="keda"
KEDA_RELEASE="keda"

# Installs a release with one queue entry per remaining argument, each named
# after and serving the queue of the same name.
install_runner_chart() {
	local release="$1"
	local namespace="$2"
	shift 2
	local args=()
	for queue in "$@"; do
		args+=(--set-string "queues.${queue}.queue=${queue}" --set "queues.${queue}.maxReplicas=1")
	done
	"${HELM_CLUSTER[@]}" install "${release}" "${CHART_DIR}" \
		--namespace "${namespace}" \
		--set-string defaults.image.repository=registry.k8s.io/pause \
		--set-string defaults.image.tag=3.10 \
		--set-string defaults.image.pullPolicy=IfNotPresent \
		--set defaults.terminationGracePeriodSeconds=5 \
		--set-string agentToken.value=not-a-real-agent-token \
		"${args[@]}"
}

runner_pods() {
	"${KUBECTL[@]}" get pods -n "$1" -l "app.kubernetes.io/component=runner,buildkite.com/runner-set=$2" -o name
}

cleanup() {
	"${HELM_CLUSTER[@]}" uninstall "${RELEASE}" --namespace "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
	"${HELM_CLUSTER[@]}" uninstall "${SECOND_RELEASE}" --namespace "${SECOND_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
	"${HELM_CLUSTER[@]}" uninstall "${KEDA_RELEASE}" --namespace "${KEDA_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
	"${KUBECTL[@]}" delete namespace "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
	"${KUBECTL[@]}" delete namespace "${SECOND_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
	"${KUBECTL[@]}" delete namespace "${KEDA_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

"${KUBECTL[@]}" create namespace "${NAMESPACE}"
"${KUBECTL[@]}" create namespace "${SECOND_NAMESPACE}"
if output=$(install_runner_chart "${RELEASE}" "${NAMESPACE}" e2e 2>&1); then
	echo "Expected installation without KEDA to fail" >&2
	exit 1
fi
[[ "${output}" == *"KEDA is required"* ]]

"${HELM_CLUSTER[@]}" upgrade --install "${KEDA_RELEASE}" keda \
	--repo https://kedacore.github.io/charts \
	--version 2.20.0 \
	--namespace "${KEDA_NAMESPACE}" \
	--create-namespace \
	--wait \
	--timeout 3m

install_runner_chart "${RELEASE}" "${NAMESPACE}" e2e e2e-other
install_runner_chart "${SECOND_RELEASE}" "${SECOND_NAMESPACE}" e2e-secondary

"${KUBECTL[@]}" rollout status deployment/keda-operator -n "${KEDA_NAMESPACE}" --timeout=2m
"${KUBECTL[@]}" rollout status deployment/keda-operator-metrics-apiserver -n "${KEDA_NAMESPACE}" --timeout=2m
"${KUBECTL[@]}" get secret/buildkite-runners-buildkite-operator-agent-token -n "${NAMESPACE}" >/dev/null
"${KUBECTL[@]}" get deployment/"${RUNNERS}" -n "${NAMESPACE}" >/dev/null
"${KUBECTL[@]}" get scaledobject/"${RUNNERS}" -n "${NAMESPACE}" >/dev/null
"${KUBECTL[@]}" get triggerauthentication/"${RELEASE}-buildkite-operator-metrics" -n "${NAMESPACE}" >/dev/null
"${KUBECTL[@]}" get deployment/"${OTHER_RUNNERS}" -n "${NAMESPACE}" >/dev/null
"${KUBECTL[@]}" get scaledobject/"${OTHER_RUNNERS}" -n "${NAMESPACE}" >/dev/null
"${KUBECTL[@]}" get deployment/"${SECOND_RUNNERS}" -n "${SECOND_NAMESPACE}" >/dev/null
"${KUBECTL[@]}" get scaledobject/"${SECOND_RUNNERS}" -n "${SECOND_NAMESPACE}" >/dev/null
"${KUBECTL[@]}" get triggerauthentication/"${SECOND_RELEASE}-buildkite-operator-metrics" -n "${SECOND_NAMESPACE}" >/dev/null

# Each queue entry's Deployment owns exactly its own runner Pod.
pod=""
other_pod=""
for _ in $(seq 1 60); do
	pod=$(runner_pods "${NAMESPACE}" e2e)
	other_pod=$(runner_pods "${NAMESPACE}" e2e-other)
	if [[ -n "${pod}" && -n "${other_pod}" ]]; then
		break
	fi
	sleep 1
done
if [[ -z "${pod}" || -z "${other_pod}" ]]; then
	echo "Each queue entry's Deployment did not create a runner Pod" >&2
	exit 1
fi
[[ $(wc -l <<<"${pod}") -eq 1 && $(wc -l <<<"${other_pod}") -eq 1 ]]
# The stand-in image never becomes Ready, so check ownership rather than
# rollout: each Deployment must count exactly its own Pod.
for deployment in "${RUNNERS}" "${OTHER_RUNNERS}"; do
	replicas=""
	for _ in $(seq 1 30); do
		replicas=$("${KUBECTL[@]}" get deployment/"${deployment}" -n "${NAMESPACE}" -o jsonpath='{.status.replicas}')
		[[ "${replicas}" == 1 ]] && break
		sleep 1
	done
	[[ "${replicas}" == 1 ]] || {
		echo "Deployment ${deployment} counted ${replicas:-0} Pods, expected only its own" >&2
		exit 1
	}
done
other_queue=$("${KUBECTL[@]}" get "${other_pod}" -n "${NAMESPACE}" -o jsonpath='{.spec.containers[0].env[?(@.name=="BUILDKITE_AGENT_TAGS")].value}')
[[ "${other_queue}" == "queue=e2e-other,runtime=standard" ]]

owner=$("${KUBECTL[@]}" get "${pod}" -n "${NAMESPACE}" -o jsonpath='{.metadata.ownerReferences[0].kind}')
[[ "${owner}" == "ReplicaSet" ]]
queue=$("${KUBECTL[@]}" get "${pod}" -n "${NAMESPACE}" -o jsonpath='{.spec.containers[0].env[?(@.name=="BUILDKITE_AGENT_TAGS")].value}')
[[ "${queue}" == "queue=e2e,runtime=standard" ]]

# The pause image has no agent status endpoint, so the sidecar must keep the
# retention annotations by successfully patching its own Pod with the chart's
# RBAC.
patched=false
for _ in $(seq 1 90); do
	if "${KUBECTL[@]}" logs "${pod}" -n "${NAMESPACE}" -c deletion-cost 2>/dev/null | grep -q '^Marked Pod busy$'; then
		patched=true
		break
	fi
	sleep 1
done
if [[ "${patched}" != true ]]; then
	echo "Deletion-cost sidecar did not patch its Pod" >&2
	"${KUBECTL[@]}" logs "${pod}" -n "${NAMESPACE}" -c deletion-cost >&2 || true
	exit 1
fi
cost=$("${KUBECTL[@]}" get "${pod}" -n "${NAMESPACE}" -o jsonpath='{.metadata.annotations.controller\.kubernetes\.io/pod-deletion-cost}')
[[ "${cost}" == "100" ]]
safe_to_evict=$("${KUBECTL[@]}" get "${pod}" -n "${NAMESPACE}" -o jsonpath='{.metadata.annotations.cluster-autoscaler\.kubernetes\.io/safe-to-evict}')
[[ "${safe_to_evict}" == "false" ]]

"${HELM_CLUSTER[@]}" uninstall "${RELEASE}" --namespace "${NAMESPACE}" --wait --timeout 2m
for _ in $(seq 1 60); do
	pod=$("${KUBECTL[@]}" get pods -n "${NAMESPACE}" -l app.kubernetes.io/component=runner -o name)
	if [[ -z "${pod}" ]]; then
		break
	fi
	sleep 1
done
[[ -z "${pod}" ]]
if "${KUBECTL[@]}" get scaledobject/"${RUNNERS}" -n "${NAMESPACE}" >/dev/null 2>&1; then
	echo "ScaledObject remained after chart uninstall" >&2
	exit 1
fi
"${KUBECTL[@]}" get deployment/"${SECOND_RUNNERS}" -n "${SECOND_NAMESPACE}" >/dev/null
"${KUBECTL[@]}" get scaledobject/"${SECOND_RUNNERS}" -n "${SECOND_NAMESPACE}" >/dev/null
"${KUBECTL[@]}" rollout status deployment/keda-operator -n "${KEDA_NAMESPACE}" --timeout=30s
"${HELM_CLUSTER[@]}" uninstall "${SECOND_RELEASE}" --namespace "${SECOND_NAMESPACE}" --wait --timeout 2m
