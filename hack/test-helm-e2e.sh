#!/usr/bin/env bash

set -euo pipefail

HELM="${HELM:-helm}"
CHART_DIR="${HELM_CHART_DIR:-charts/buildkite-operator}"
NAMESPACE="buildkite-runners"
RELEASE="buildkite-runners"
RUNNERS="buildkite-runners-buildkite-operator-runners"

cleanup() {
	"${HELM}" uninstall "${RELEASE}" --namespace "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
	kubectl delete namespace "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

kubectl create namespace "${NAMESPACE}"
"${HELM}" install "${RELEASE}" "${CHART_DIR}" \
	--namespace "${NAMESPACE}" \
	--set-string runners.queue=e2e \
	--set runners.maxReplicas=1 \
	--set-string runners.image.repository=registry.k8s.io/pause \
	--set-string runners.image.tag=3.10 \
	--set-string runners.image.pullPolicy=IfNotPresent \
	--set runners.terminationGracePeriodSeconds=5 \
	--set-string agentToken.value=not-a-real-agent-token

kubectl rollout status deployment/keda-operator -n "${NAMESPACE}" --timeout=2m
kubectl rollout status deployment/keda-operator-metrics-apiserver -n "${NAMESPACE}" --timeout=2m
kubectl get secret/buildkite-runners-buildkite-operator-agent-token -n "${NAMESPACE}" >/dev/null
kubectl get deployment/"${RUNNERS}" -n "${NAMESPACE}" >/dev/null
kubectl get scaledobject/"${RUNNERS}" -n "${NAMESPACE}" >/dev/null
kubectl get triggerauthentication/"${RUNNERS}" -n "${NAMESPACE}" >/dev/null

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

"${HELM}" uninstall "${RELEASE}" --namespace "${NAMESPACE}"
for _ in $(seq 1 60); do
	pod=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/component=runner -o name)
	if [[ -z "${pod}" ]]; then
		break
	fi
	sleep 1
done
[[ -z "${pod}" ]]
