#!/usr/bin/env bash

set -euo pipefail

HELM="${HELM:-helm}"
CHART_DIR="${HELM_CHART_DIR:-charts/buildkite-operator}"
NAMESPACE="buildkite-operator-system"
RELEASE="buildkite-operator"
POOL="buildkite-operator-runner-pool"

cleanup() {
	"${HELM}" uninstall "${RELEASE}" --namespace "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
	kubectl delete namespace "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
	kubectl delete crd runnerpools.buildkite.com --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

kubectl create namespace "${NAMESPACE}"
"${HELM}" install "${RELEASE}" "${CHART_DIR}" \
	--namespace "${NAMESPACE}" \
	--set-string manager.image.repository=example.com/buildkite-operator \
	--set-string manager.image.tag=v0.0.1 \
	--set-string runnerPool.queue=e2e \
	--set runnerPool.maxRunners=1 \
	--set-string runnerPool.image=registry.k8s.io/pause:3.10 \
	--set runnerPool.terminationGracePeriodSeconds=5 \
	--set-string agentToken.value=not-a-real-agent-token

kubectl rollout status deployment/buildkite-operator -n "${NAMESPACE}" --timeout=2m
kubectl get secret/buildkite-operator-agent-token -n "${NAMESPACE}" >/dev/null
kubectl get runnerpool/"${POOL}" -n "${NAMESPACE}" >/dev/null

pod=""
for _ in $(seq 1 60); do
	pod=$(kubectl get pods -n "${NAMESPACE}" -l "buildkite.com/runner-pool=${POOL}" -o name)
	if [[ -n "${pod}" ]]; then
		break
	fi
	sleep 1
done
if [[ -z "${pod}" ]]; then
	echo "RunnerPool did not create an agent Pod" >&2
	exit 1
fi

owner=$(kubectl get "${pod}" -n "${NAMESPACE}" -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}')
[[ "${owner}" == "RunnerPool/${POOL}" ]]
queue=$(kubectl get "${pod}" -n "${NAMESPACE}" -o jsonpath='{.spec.containers[0].env[?(@.name=="BUILDKITE_AGENT_TAGS")].value}')
[[ "${queue}" == "queue=e2e" ]]

"${HELM}" uninstall "${RELEASE}" --namespace "${NAMESPACE}"
for _ in $(seq 1 60); do
	pod=$(kubectl get pods -n "${NAMESPACE}" -l "buildkite.com/runner-pool=${POOL}" -o name)
	if [[ -z "${pod}" ]]; then
		break
	fi
	sleep 1
done
[[ -z "${pod}" ]]
kubectl get crd runnerpools.buildkite.com >/dev/null
