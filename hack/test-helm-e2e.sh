#!/usr/bin/env bash

set -euo pipefail

HELM="${HELM:-helm}"
CHART_DIR="${HELM_CHART_DIR:-charts/buildkite-operator}"
NAMESPACE="buildkite-runners"
RELEASE="buildkite-runners"
RUNNERS="buildkite-runners-buildkite-operator-runners"
SECOND_NAMESPACE="buildkite-runners-two"
SECOND_RELEASE="buildkite-runners-two"
SECOND_RUNNERS="buildkite-runners-two-buildkite-operator-runners"
KEDA_NAMESPACE="keda"
KEDA_RELEASE="keda"

install_runner_chart() {
	local release="$1"
	local namespace="$2"
	local queue="$3"
	"${HELM}" install "${release}" "${CHART_DIR}" \
		--namespace "${namespace}" \
		--set-string runners.queue="${queue}" \
		--set runners.maxReplicas=1 \
		--set-string runners.image.repository=registry.k8s.io/pause \
		--set-string runners.image.tag=3.10 \
		--set-string runners.image.pullPolicy=IfNotPresent \
		--set runners.terminationGracePeriodSeconds=5 \
		--set-string agentToken.value=not-a-real-agent-token
}

cleanup() {
	"${HELM}" uninstall "${RELEASE}" --namespace "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
	"${HELM}" uninstall "${SECOND_RELEASE}" --namespace "${SECOND_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
	"${HELM}" uninstall "${KEDA_RELEASE}" --namespace "${KEDA_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
	kubectl delete namespace "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
	kubectl delete namespace "${SECOND_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
	kubectl delete namespace "${KEDA_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

kubectl create namespace "${NAMESPACE}"
kubectl create namespace "${SECOND_NAMESPACE}"
if output=$(install_runner_chart "${RELEASE}" "${NAMESPACE}" e2e 2>&1); then
	echo "Expected installation without KEDA to fail" >&2
	exit 1
fi
[[ "${output}" == *"KEDA is required"* ]]

"${HELM}" upgrade --install "${KEDA_RELEASE}" keda \
	--repo https://kedacore.github.io/charts \
	--version 2.20.0 \
	--namespace "${KEDA_NAMESPACE}" \
	--create-namespace \
	--wait \
	--timeout 3m

install_runner_chart "${RELEASE}" "${NAMESPACE}" e2e
install_runner_chart "${SECOND_RELEASE}" "${SECOND_NAMESPACE}" e2e-secondary

kubectl rollout status deployment/keda-operator -n "${KEDA_NAMESPACE}" --timeout=2m
kubectl rollout status deployment/keda-operator-metrics-apiserver -n "${KEDA_NAMESPACE}" --timeout=2m
kubectl get secret/buildkite-runners-buildkite-operator-agent-token -n "${NAMESPACE}" >/dev/null
kubectl get deployment/"${RUNNERS}" -n "${NAMESPACE}" >/dev/null
kubectl get scaledobject/"${RUNNERS}" -n "${NAMESPACE}" >/dev/null
kubectl get triggerauthentication/"${RUNNERS}" -n "${NAMESPACE}" >/dev/null
kubectl get deployment/"${SECOND_RUNNERS}" -n "${SECOND_NAMESPACE}" >/dev/null
kubectl get scaledobject/"${SECOND_RUNNERS}" -n "${SECOND_NAMESPACE}" >/dev/null
kubectl get triggerauthentication/"${SECOND_RUNNERS}" -n "${SECOND_NAMESPACE}" >/dev/null

pod=""
for _ in $(seq 1 60); do
	pod=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/component=runner -o name)
	if [[ -n "${pod}" ]]; then
		break
	fi
	sleep 1
done
if [[ -z "${pod}" ]]; then
	echo "Deployment did not create a runner Pod" >&2
	exit 1
fi

owner=$(kubectl get "${pod}" -n "${NAMESPACE}" -o jsonpath='{.metadata.ownerReferences[0].kind}')
[[ "${owner}" == "ReplicaSet" ]]
queue=$(kubectl get "${pod}" -n "${NAMESPACE}" -o jsonpath='{.spec.containers[0].env[?(@.name=="BUILDKITE_AGENT_TAGS")].value}')
[[ "${queue}" == "queue=e2e,runtime=standard" ]]

"${HELM}" uninstall "${RELEASE}" --namespace "${NAMESPACE}" --wait --timeout 2m
for _ in $(seq 1 60); do
	pod=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/component=runner -o name)
	if [[ -z "${pod}" ]]; then
		break
	fi
	sleep 1
done
[[ -z "${pod}" ]]
if kubectl get scaledobject/"${RUNNERS}" -n "${NAMESPACE}" >/dev/null 2>&1; then
	echo "ScaledObject remained after chart uninstall" >&2
	exit 1
fi
kubectl get deployment/"${SECOND_RUNNERS}" -n "${SECOND_NAMESPACE}" >/dev/null
kubectl get scaledobject/"${SECOND_RUNNERS}" -n "${SECOND_NAMESPACE}" >/dev/null
kubectl rollout status deployment/keda-operator -n "${KEDA_NAMESPACE}" --timeout=30s
"${HELM}" uninstall "${SECOND_RELEASE}" --namespace "${SECOND_NAMESPACE}" --wait --timeout 2m
