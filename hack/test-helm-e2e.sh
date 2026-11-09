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
# The first release serves four runner pools to verify they stay independent.
RUNNERS="${RELEASE}-e2e"
OTHER_RUNNERS="${RELEASE}-e2e-other"
EPHEMERAL_RUNNERS="${RELEASE}-e2e-ephemeral"
DIND_RUNNERS="${RELEASE}-e2e-dind"
SECOND_NAMESPACE="buildkite-runners-two"
SECOND_RELEASE="buildkite-runners-two"
SECOND_RUNNERS="${SECOND_RELEASE}-e2e-secondary"
ACCEL_NAMESPACE="buildkite-runners-accel"
ACCEL_RELEASE="accel"
ACCEL_NAME="${ACCEL_RELEASE}-buildkite-operator-oci-accelerator"
ACCEL_CA_SECRET="${ACCEL_NAME}-ca"
ACCEL_CA_CONFIGMAP="${ACCEL_NAME}-ca-cert"
ACCEL_IMAGE=$("${HELM}" show values "${CHART_DIR}" | awk '
	/^ociAccelerator:/ { section = 1; next }
	section && /^[^ #]/ { section = 0 }
	section && $1 == "repository:" { repository = $2 }
	section && $1 == "digest:" { digest = $2 }
	END { print repository "@" digest }')
KEDA_NAMESPACE="keda"
KEDA_RELEASE="keda"

# Installs a release with one runner pool per remaining argument, each named
# after and serving the queue of the same name. Arguments after -- are passed
# to Helm.
install_runner_chart() {
	local release="$1"
	local namespace="$2"
	shift 2
	local args=()
	while [[ $# -gt 0 && "$1" != -- ]]; do
		args+=(--set-string "runnerPools.$1.queue=$1" --set "runnerPools.$1.maxReplicas=1")
		shift
	done
	[[ $# -gt 0 ]] && shift
	args+=("$@")
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
	"${KUBECTL[@]}" get pods -n "$1" -l "app.kubernetes.io/component=runner,buildkite.com/runner-pool=$2" -o name
}

cleanup() {
	"${HELM_CLUSTER[@]}" uninstall "${RELEASE}" --namespace "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
	"${HELM_CLUSTER[@]}" uninstall "${SECOND_RELEASE}" --namespace "${SECOND_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
	"${HELM_CLUSTER[@]}" uninstall "${ACCEL_RELEASE}" --namespace "${ACCEL_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
	"${KUBECTL[@]}" delete namespace "${ACCEL_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
	"${HELM_CLUSTER[@]}" uninstall "${KEDA_RELEASE}" --namespace "${KEDA_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
	"${KUBECTL[@]}" delete namespace "${NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
	"${KUBECTL[@]}" delete namespace "${SECOND_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
	"${KUBECTL[@]}" delete namespace "${KEDA_NAMESPACE}" --ignore-not-found >/dev/null 2>&1 || true
	rm -rf "${agent_dir:-}" "${agent_logs:-}" "${api_ca:-}" "${patch_response:-}"
}
trap cleanup EXIT

# Temporarily pin Kind 0.30's Kindnet (policy engine v0.8.0). Newer engines
# require CONFIG_NETFILTER_NETLINK_GLUE_CT to label allowed connections, which
# CI's kernel lacks. Remove the pin when that capability is available on CI.
"${KUBECTL[@]}" set image daemonset/kindnet -n kube-system \
	kindnet-cni=docker.io/kindest/kindnetd:v20250512-df8de77b@sha256:07a4b3fe0077a0ae606cc0a200fc25a28fa64dcc30b8d311b461089969449f9a
"${KUBECTL[@]}" rollout status daemonset/kindnet -n kube-system --timeout=1m

# The pause image stands in for persistent agents. Ephemeral standard agents
# need a shell, so they use busybox with a stand-in agent mounted from a
# ConfigMap. The stand-in serves the health and status endpoints, records
# which agent ran in the workspace, and runs a "job" until the test releases
# it. Like the real agent, it finishes its job on SIGTERM.
agent_dir=$(mktemp -d)
cat >"${agent_dir}/buildkite-agent" <<'AGENT'
#!/bin/sh
[ "$*" = "start --disconnect-after-job" ] || { echo "unexpected arguments: $*" >&2; exit 64; }
mkdir -p /tmp/www/agent "$BUILDKITE_BUILD_PATH"
echo ok >/tmp/www/agent/1
echo '{"aggregate_status":"idle"}' >/tmp/www/status.json
httpd -f -p 8080 -h /tmp/www &
httpd_pid=$!
touch "$BUILDKITE_BUILD_PATH/$BUILDKITE_AGENT_NAME"
echo "Started agent $BUILDKITE_AGENT_NAME"
terms=0
trap 'terms=$((terms + 1))' TERM
until [ -e "/tmp/release-$BUILDKITE_AGENT_NAME" ] || [ "$terms" -gt 0 ]; do sleep 0.2; done
if [ "$terms" -gt 0 ]; then
	sleep 3
	echo "Drained agent $BUILDKITE_AGENT_NAME after $terms SIGTERM"
fi
kill "$httpd_pid"
wait "$httpd_pid" || true
AGENT

"${KUBECTL[@]}" create namespace "${NAMESPACE}"
"${KUBECTL[@]}" create namespace "${SECOND_NAMESPACE}"
"${KUBECTL[@]}" create configmap stand-in-agent -n "${NAMESPACE}" --from-file="${agent_dir}/buildkite-agent"
if output=$(install_runner_chart "${RELEASE}" "${NAMESPACE}" e2e 2>&1); then
	echo "Expected installation without KEDA to fail" >&2
	exit 1
fi
[[ "${output}" == *"KEDA is required"* ]]

# KEDA usually becomes ready within a minute, but on CI it has sometimes taken
# over three. Show why before the cluster is deleted if it does not become ready.
if ! "${HELM_CLUSTER[@]}" upgrade --install "${KEDA_RELEASE}" keda \
	--repo https://kedacore.github.io/charts \
	--version 2.20.0 \
	--namespace "${KEDA_NAMESPACE}" \
	--create-namespace \
	--wait \
	--timeout 5m; then
	echo "KEDA did not become ready" >&2
	"${KUBECTL[@]}" get pods -n "${KEDA_NAMESPACE}" -o wide >&2 || true
	"${KUBECTL[@]}" describe pods -n "${KEDA_NAMESPACE}" >&2 || true
	"${KUBECTL[@]}" get events -n "${KEDA_NAMESPACE}" --sort-by=.lastTimestamp >&2 || true
	exit 1
fi

# The dind queue's Docker daemon requests far less than the chart's default so
# it fits on the single Kind node.
install_runner_chart "${RELEASE}" "${NAMESPACE}" e2e e2e-other e2e-ephemeral e2e-dind -- \
	--set-string runnerPools.e2e-dind.runtime=dind \
	--set-string runnerPools.e2e-dind.docker.resources.requests.cpu=100m \
	--set-string runnerPools.e2e-dind.docker.resources.requests.memory=256Mi \
	--set-string runnerPools.e2e-dind.docker.resources.requests.ephemeral-storage=1Gi \
	--set runnerPools.e2e-ephemeral.ephemeralAgent=true \
	--set-string runnerPools.e2e-ephemeral.image.repository=busybox \
	--set-string runnerPools.e2e-ephemeral.image.tag=1.37 \
	--set runnerPools.e2e-ephemeral.terminationGracePeriodSeconds=30
# The chart has no hook for extra volumes, so mount the stand-in agent where
# the chart runs buildkite-agent. This rolls out a second Pod.
"${KUBECTL[@]}" patch deployment/"${EPHEMERAL_RUNNERS}" -n "${NAMESPACE}" --patch '
spec:
  template:
    spec:
      volumes:
        - name: stand-in-agent
          configMap: {name: stand-in-agent, defaultMode: 493}
      containers:
        - name: agent
          volumeMounts:
            - {name: stand-in-agent, mountPath: /usr/local/bin/buildkite-agent, subPath: buildkite-agent}
'
install_runner_chart "${SECOND_RELEASE}" "${SECOND_NAMESPACE}" e2e-secondary

"${KUBECTL[@]}" rollout status deployment/keda-operator -n "${KEDA_NAMESPACE}" --timeout=2m
"${KUBECTL[@]}" rollout status deployment/keda-operator-metrics-apiserver -n "${KEDA_NAMESPACE}" --timeout=2m
"${KUBECTL[@]}" get secret/buildkite-runners-buildkite-operator-agent-token -n "${NAMESPACE}" >/dev/null
"${KUBECTL[@]}" get deployment/"${RUNNERS}" -n "${NAMESPACE}" >/dev/null
"${KUBECTL[@]}" get scaledobject/"${RUNNERS}" -n "${NAMESPACE}" >/dev/null
"${KUBECTL[@]}" get triggerauthentication/"${RELEASE}-buildkite-operator-metrics" -n "${NAMESPACE}" >/dev/null
"${KUBECTL[@]}" get deployment/"${OTHER_RUNNERS}" -n "${NAMESPACE}" >/dev/null
"${KUBECTL[@]}" get deployment/"${DIND_RUNNERS}" -n "${NAMESPACE}" >/dev/null
"${KUBECTL[@]}" get scaledobject/"${OTHER_RUNNERS}" -n "${NAMESPACE}" >/dev/null
"${KUBECTL[@]}" get deployment/"${SECOND_RUNNERS}" -n "${SECOND_NAMESPACE}" >/dev/null
"${KUBECTL[@]}" get scaledobject/"${SECOND_RUNNERS}" -n "${SECOND_NAMESPACE}" >/dev/null
"${KUBECTL[@]}" get triggerauthentication/"${SECOND_RELEASE}-buildkite-operator-metrics" -n "${SECOND_NAMESPACE}" >/dev/null

# Each runner pool's Deployment owns exactly its own runner Pod.
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
	echo "Each runner pool's Deployment did not create a runner Pod" >&2
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

# The chart's admission policy limits the sidecar's token to the scale-in
# annotations on its own Pod. Patch with that token as the sidecar does, or as
# someone who took it from the node would.
api_ca=$(mktemp)
"${KUBECTL[@]}" config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d >"${api_ca}"
api_server=$("${KUBECTL[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}')
sidecar_token=$("${KUBECTL[@]}" exec "${pod}" -n "${NAMESPACE}" -c deletion-cost -- cat /var/run/secrets/kubernetes.io/serviceaccount/token)
patch_response=$(mktemp)
# Usage: patch_as_sidecar <pod> <patch type> <patch>. Prints the HTTP status,
# then the response.
patch_as_sidecar() {
	curl -sS --cacert "${api_ca}" -o "${patch_response}" -w '%{http_code}' -X PATCH \
		-H "Authorization: Bearer ${sidecar_token}" -H "Content-Type: application/$2" --data "$3" \
		"${api_server}/api/v1/namespaces/${NAMESPACE}/pods/${1#pod/}"
	echo " $(cat "${patch_response}")"
}
# The policy can take a moment to take effect after install.
for _ in $(seq 1 30); do
	result=$(patch_as_sidecar "${other_pod}" merge-patch+json '{"metadata":{"annotations":{"cluster-autoscaler.kubernetes.io/safe-to-evict":"true"}}}')
	[[ "${result}" == 422* ]] && break
	sleep 1
done
[[ "${result}" == *"The deletion-cost sidecar may only patch its own Pod"* ]] || {
	echo "The sidecar's token patched another Pod: ${result}" >&2
	exit 1
}
result=$(patch_as_sidecar "${pod}" json-patch+json '[{"op":"replace","path":"/spec/containers/0/image","value":"busybox:1.37"}]')
[[ "${result}" == *"The deletion-cost sidecar may only change the pod-deletion-cost and safe-to-evict annotations"* ]] || {
	echo "The sidecar's token changed its own Pod's image: ${result}" >&2
	exit 1
}
# The sidecar's own patches, including removing the cost with null.
result=$(patch_as_sidecar "${pod}" merge-patch+json '{"metadata":{"annotations":{"controller.kubernetes.io/pod-deletion-cost":null,"cluster-autoscaler.kubernetes.io/safe-to-evict":"true"}}}')
[[ "${result}" == "200 "* ]] || { echo "The sidecar could not mark its own Pod idle: ${result}" >&2; exit 1; }
[[ -z "$("${KUBECTL[@]}" get "${pod}" -n "${NAMESPACE}" -o jsonpath='{.metadata.annotations.controller\.kubernetes\.io/pod-deletion-cost}')" ]]
result=$(patch_as_sidecar "${pod}" merge-patch+json '{"metadata":{"annotations":{"controller.kubernetes.io/pod-deletion-cost":"100","cluster-autoscaler.kubernetes.io/safe-to-evict":"false"}}}')
[[ "${result}" == "200 "* ]] || { echo "The sidecar could not mark its own Pod busy: ${result}" >&2; exit 1; }
[[ "$("${KUBECTL[@]}" get "${pod}" -n "${NAMESPACE}" -o jsonpath='{.metadata.annotations.controller\.kubernetes\.io/pod-deletion-cost}')" == 100 ]]

# Ephemeral standard agents: each job gets a newly registered agent and a clean
# workspace while the container keeps running.
ephemeral_pod=""
for _ in $(seq 1 60); do
	ephemeral_pod=$(runner_pods "${NAMESPACE}" e2e-ephemeral)
	[[ -n "${ephemeral_pod}" ]] && break
	sleep 1
done
[[ -n "${ephemeral_pod}" ]] || { echo "The ephemeral runner pool did not create a runner Pod" >&2; exit 1; }
"${KUBECTL[@]}" rollout status deployment/"${EPHEMERAL_RUNNERS}" -n "${NAMESPACE}" --timeout=2m
# Wait for the Pod from before the patch to go.
for _ in $(seq 1 60); do
	ephemeral_pod=$(runner_pods "${NAMESPACE}" e2e-ephemeral)
	[[ $(wc -l <<<"${ephemeral_pod}") -eq 1 ]] && break
	sleep 1
done
[[ $(wc -l <<<"${ephemeral_pod}") -eq 1 ]] || { echo "The unpatched ephemeral runner Pod did not go" >&2; exit 1; }
"${KUBECTL[@]}" wait --for=condition=Ready "${ephemeral_pod}" -n "${NAMESPACE}" --timeout=2m
in_agent() { "${KUBECTL[@]}" exec "${ephemeral_pod}" -n "${NAMESPACE}" -c agent -- "$@"; }
first=$(in_agent ls -A /buildkite/builds)
[[ "${first}" == "${ephemeral_pod#pod/}"-???? ]] || { echo "Unexpected first agent workspace: ${first}" >&2; exit 1; }
in_agent sh -c 'mkdir -p /buildkite/plugins && touch /buildkite/builds/.leftover /buildkite/plugins/leftover /tmp/outside-workspace'
in_agent touch "/tmp/release-${first}"
second=""
for _ in $(seq 1 30); do
	second=$(in_agent ls -A /buildkite/builds)
	[[ -n "${second}" && "${second}" != *"${first}"* ]] && break
	sleep 1
done
[[ "${second}" == "${ephemeral_pod#pod/}"-???? ]] || {
	echo "Workspace was not reset for a new agent: ${second}" >&2
	"${KUBECTL[@]}" logs "${ephemeral_pod}" -n "${NAMESPACE}" -c agent >&2 || true
	exit 1
}
[[ -z "$(in_agent ls -A /buildkite/plugins)" ]] || { echo "Plugins were not reset between jobs" >&2; exit 1; }
in_agent test -e /tmp/outside-workspace # Only the workspace is reset.
restarts=$("${KUBECTL[@]}" get "${ephemeral_pod}" -n "${NAMESPACE}" -o jsonpath='{.status.containerStatuses[?(@.name=="agent")].restartCount}')
[[ "${restarts}" == 0 ]] || { echo "Agent container restarted ${restarts} time(s) between jobs" >&2; exit 1; }
# The stand-in reports idle, so the sidecar must settle on the idle annotations
# once the replacement agent is up.
safe_to_evict=""
for _ in $(seq 1 30); do
	safe_to_evict=$("${KUBECTL[@]}" get "${ephemeral_pod}" -n "${NAMESPACE}" -o jsonpath='{.metadata.annotations.cluster-autoscaler\.kubernetes\.io/safe-to-evict}')
	[[ "${safe_to_evict}" == "true" ]] && break
	sleep 1
done
[[ "${safe_to_evict}" == "true" ]] || { echo "Ephemeral runner was not marked idle" >&2; exit 1; }
cost=$("${KUBECTL[@]}" get "${ephemeral_pod}" -n "${NAMESPACE}" -o jsonpath='{.metadata.annotations.controller\.kubernetes\.io/pod-deletion-cost}')
[[ -z "${cost}" ]]
# Deleting the Pod must let the in-flight job drain, then stop the container
# well before the grace period ends.
agent_logs=$(mktemp)
"${KUBECTL[@]}" logs --follow "${ephemeral_pod}" -n "${NAMESPACE}" -c agent >"${agent_logs}" &
logs_pid=$!
sleep 1
started=$(date +%s)
"${KUBECTL[@]}" delete "${ephemeral_pod}" -n "${NAMESPACE}" --wait --timeout=1m
elapsed=$(($(date +%s) - started))
wait "${logs_pid}" || true
if ! grep -q "^Drained agent ${second} after 1 SIGTERM$" "${agent_logs}" ||
	! grep -q '^ephemeral-agent: Stopped$' "${agent_logs}"; then
	echo "Ephemeral agent did not drain its job on a single SIGTERM" >&2
	cat "${agent_logs}" >&2
	exit 1
fi
[[ "${elapsed}" -lt 25 ]] || { echo "Ephemeral runner took ${elapsed}s to stop" >&2; exit 1; }

# dind: a real privileged Docker daemon starts on an ordinary node, and can run
# containers. The Pod is Initialized once the daemon's startup probe passes.
dind_pod=""
for _ in $(seq 1 60); do
	dind_pod=$(runner_pods "${NAMESPACE}" e2e-dind)
	[[ -n "${dind_pod}" ]] && break
	sleep 1
done
[[ -n "${dind_pod}" ]] || { echo "The dind runner pool did not create a runner Pod" >&2; exit 1; }
"${KUBECTL[@]}" wait --for=condition=Initialized "${dind_pod}" -n "${NAMESPACE}" --timeout=3m || {
	"${KUBECTL[@]}" describe "${dind_pod}" -n "${NAMESPACE}" >&2 || true
	"${KUBECTL[@]}" logs "${dind_pod}" -n "${NAMESPACE}" -c dockerd >&2 || true
	exit 1
}
[[ -z "$("${KUBECTL[@]}" get "${dind_pod}" -n "${NAMESPACE}" -o jsonpath='{.spec.runtimeClassName}')" ]]
privileged=$("${KUBECTL[@]}" get "${dind_pod}" -n "${NAMESPACE}" -o jsonpath='{.spec.initContainers[?(@.name=="dockerd")].securityContext.privileged}')
[[ "${privileged}" == true ]]
in_dockerd() { "${KUBECTL[@]}" exec "${dind_pod}" -n "${NAMESPACE}" -c dockerd -- "$@"; }
[[ -n "$(in_dockerd docker info --format '{{.ServerVersion}}')" ]]
[[ "$(in_dockerd docker run --quiet --rm --network none busybox:1.37 echo ran)" == ran ]] || {
	echo "dind Docker daemon could not run a container" >&2
	exit 1
}

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
if "${KUBECTL[@]}" get validatingadmissionpolicy "${NAMESPACE}-${RELEASE}-buildkite-operator-deletion-cost" >/dev/null 2>&1; then
	echo "Deletion-cost admission policy remained after chart uninstall" >&2
	exit 1
fi
"${KUBECTL[@]}" get deployment/"${SECOND_RUNNERS}" -n "${SECOND_NAMESPACE}" >/dev/null
"${KUBECTL[@]}" get scaledobject/"${SECOND_RUNNERS}" -n "${SECOND_NAMESPACE}" >/dev/null
"${KUBECTL[@]}" rollout status deployment/keda-operator -n "${KEDA_NAMESPACE}" --timeout=30s
"${HELM_CLUSTER[@]}" uninstall "${SECOND_RELEASE}" --namespace "${SECOND_NAMESPACE}" --wait --timeout 2m

# The OCI accelerator caches pulls by the Docker daemon in a dind runner Pod,
# with a CA the chart generates. Its NetworkPolicy is enabled only after the
# pulls: on some CI hosts, Kind's policy enforcement drops replies to the
# proxy's own upstream connections, which the policy does not restrict.
"${KUBECTL[@]}" create namespace "${ACCEL_NAMESPACE}"
"${HELM_CLUSTER[@]}" install "${ACCEL_RELEASE}" "${CHART_DIR}" \
	--namespace "${ACCEL_NAMESPACE}" \
	--set-string defaults.image.repository=registry.k8s.io/pause \
	--set-string defaults.image.tag=3.10 \
	--set-string defaults.image.pullPolicy=IfNotPresent \
	--set defaults.terminationGracePeriodSeconds=5 \
	--set-string defaults.docker.resources.requests.cpu=100m \
	--set-string defaults.docker.resources.requests.memory=256Mi \
	--set-string defaults.docker.resources.requests.ephemeral-storage=1Gi \
	--set-string agentToken.value=not-a-real-agent-token \
	--set-string runnerPools.accel.queue=accel \
	--set-string runnerPools.accel.runtime=dind \
	--set runnerPools.accel.maxReplicas=1 \
	--set ociAccelerator.enabled=true \
	--set ociAccelerator.networkPolicy.enabled=false \
	--set-string ociAccelerator.cache.size=1Gi \
	--set ociAccelerator.cache.maxBytes=805306368 \
	--set-string ociAccelerator.resources.requests.cpu=100m
ca_secret_cert() {
	"${KUBECTL[@]}" get secret "${ACCEL_CA_SECRET}" -n "${ACCEL_NAMESPACE}" -o jsonpath='{.data.ca\.crt}' | base64 -d
}
ca_configmap_cert() {
	"${KUBECTL[@]}" get configmap "${ACCEL_CA_CONFIGMAP}" -n "${ACCEL_NAMESPACE}" -o jsonpath='{.data.ca\.crt}'
}
generated_ca=$(ca_secret_cert)
[[ "${generated_ca}" == "-----BEGIN CERTIFICATE-----"* ]] || { echo "The chart did not generate a CA Secret" >&2; exit 1; }
[[ "$(ca_configmap_cert)" == "${generated_ca}" ]] || { echo "The CA ConfigMap does not hold the generated certificate" >&2; exit 1; }
[[ -z "$("${KUBECTL[@]}" get jobs,roles,serviceaccounts -n "${ACCEL_NAMESPACE}" -l app.kubernetes.io/component=oci-accelerator-ca -o name)" ]] || {
	echo "CA hook resources remained after install" >&2
	exit 1
}
"${KUBECTL[@]}" rollout status statefulset/"${ACCEL_NAME}" -n "${ACCEL_NAMESPACE}" --timeout=3m

dockerd_pod=""
for _ in $(seq 1 180); do
	dockerd_pod=$("${KUBECTL[@]}" get pods -n "${ACCEL_NAMESPACE}" -l app.kubernetes.io/component=runner \
		-o jsonpath='{range .items[?(@.status.initContainerStatuses[0].ready==true)]}{.metadata.name}{end}')
	[[ -n "${dockerd_pod}" ]] && break
	sleep 1
done
if [[ -z "${dockerd_pod}" ]]; then
	echo "Runner Docker daemon did not start" >&2
	"${KUBECTL[@]}" describe pods -n "${ACCEL_NAMESPACE}" -l app.kubernetes.io/component=runner >&2 || true
	exit 1
fi
dockerd() { "${KUBECTL[@]}" exec -n "${ACCEL_NAMESPACE}" "${dockerd_pod}" -c dockerd -- "$@"; }

# Runner Pods trust the CA from the ConfigMap.
runner_secrets=$("${KUBECTL[@]}" get pod "${dockerd_pod}" -n "${ACCEL_NAMESPACE}" -o jsonpath='{.spec.volumes[*].secret.secretName}')
[[ " ${runner_secrets} " != *" ${ACCEL_CA_SECRET} "* ]] || { echo "Runner Pod references the CA Secret" >&2; exit 1; }
[[ "$("${KUBECTL[@]}" get pod "${dockerd_pod}" -n "${ACCEL_NAMESPACE}" -o jsonpath='{.spec.volumes[?(@.name=="oci-accelerator-ca")].configMap.name}')" == "${ACCEL_CA_CONFIGMAP}" ]]
[[ "$(dockerd cat /etc/ssl/oci-accelerator-certs/ca.crt)" == "${generated_ca}" ]] || {
	echo "Runner Docker daemon does not trust the generated CA" >&2
	exit 1
}

# Runner Pods reach the proxy, which serves the CA from the Secret.
served_ca=$(dockerd wget -q -O - "http://${ACCEL_NAME}:3128/ca.crt")
[[ "${served_ca}" == "${generated_ca}" ]] || {
	echo "Proxy did not serve the CA from its Secret" >&2
	exit 1
}

# Upgrades keep the generated CA and recreate a missing ConfigMap from it. One
# that leaves the proxy unchanged keeps its Pod and so its cache.
proxy_pod() {
	"${KUBECTL[@]}" get pods -n "${ACCEL_NAMESPACE}" -l app.kubernetes.io/component=oci-accelerator -o jsonpath='{.items[*].metadata.uid}'
}
proxy_before=$(proxy_pod)
accelerator_uid=$("${KUBECTL[@]}" get statefulset "${ACCEL_NAME}" -n "${ACCEL_NAMESPACE}" -o jsonpath='{.metadata.uid}')
headless_uid=$("${KUBECTL[@]}" get service "${ACCEL_NAME}-peers" -n "${ACCEL_NAMESPACE}" -o jsonpath='{.metadata.uid}')
"${KUBECTL[@]}" delete configmap "${ACCEL_CA_CONFIGMAP}" -n "${ACCEL_NAMESPACE}"
"${HELM_CLUSTER[@]}" upgrade "${ACCEL_RELEASE}" "${CHART_DIR}" --namespace "${ACCEL_NAMESPACE}" --reuse-values
[[ "$(ca_secret_cert)" == "${generated_ca}" ]] || { echo "helm upgrade replaced the generated CA" >&2; exit 1; }
[[ "$(ca_configmap_cert)" == "${generated_ca}" ]] || { echo "helm upgrade did not recreate the CA ConfigMap" >&2; exit 1; }
[[ "$(proxy_pod)" == "${proxy_before}" ]] || { echo "helm upgrade replaced the unchanged proxy Pod" >&2; exit 1; }

# A second pull of a removed image is served from the cache.
image=alpine:3.20
dockerd docker pull -q "${image}"
dockerd docker image rm "${image}" >/dev/null
dockerd docker pull -q "${image}"
accelerator_logs=$("${KUBECTL[@]}" logs statefulset/"${ACCEL_NAME}" -n "${ACCEL_NAMESPACE}" -c oci-accelerator)
# Not grep -q: exiting at the first match would fail the pipeline with SIGPIPE.
if ! grep '"registry":"registry-1.docker.io"' <<<"${accelerator_logs}" | grep '"cache":"hit"' >/dev/null; then
	echo "Second pull was not served from the OCI accelerator cache" >&2
	echo "${accelerator_logs}" >&2
	exit 1
fi

# With the NetworkPolicy, runner Pods still reach the proxy but other Pods
# cannot. Enforcement can take a few seconds to apply.
"${HELM_CLUSTER[@]}" upgrade "${ACCEL_RELEASE}" "${CHART_DIR}" --namespace "${ACCEL_NAMESPACE}" --reuse-values \
	--set ociAccelerator.networkPolicy.enabled=true >/dev/null
[[ "$(proxy_pod)" == "${proxy_before}" ]] || { echo "Enabling the NetworkPolicy replaced the proxy Pod" >&2; exit 1; }
for _ in $(seq 1 6); do
	blocked=$("${KUBECTL[@]}" run blocked-probe -n "${ACCEL_NAMESPACE}" --image="${ACCEL_IMAGE}" --restart=Never \
		--rm -i --quiet --command -- wget -q -T 5 -O /dev/null "http://${ACCEL_NAME}:3128/ca.crt" 2>&1 || true)
	[[ "${blocked}" == *"timed out"* ]] && break
	sleep 2
done
[[ "$(dockerd wget -q -O - "http://${ACCEL_NAME}:3128/ca.crt")" == "${generated_ca}" ]] || {
	echo "NetworkPolicy blocked a runner Pod from the OCI accelerator" >&2
	exit 1
}
[[ "${blocked}" == *"timed out"* ]] || {
	echo "NetworkPolicy did not block a non-runner Pod from the OCI accelerator: ${blocked}" >&2
	exit 1
}

# Independent proxies scale behind the same ready-only Service without peering.
# Keep the known Kind upstream-policy workaround for pulls.
"${HELM_CLUSTER[@]}" upgrade "${ACCEL_RELEASE}" "${CHART_DIR}" --namespace "${ACCEL_NAMESPACE}" --reuse-values \
	--set ociAccelerator.replicas=2 --set ociAccelerator.networkPolicy.enabled=false >/dev/null
"${KUBECTL[@]}" rollout status statefulset/"${ACCEL_NAME}" -n "${ACCEL_NAMESPACE}" --timeout=3m
"${KUBECTL[@]}" wait --for=jsonpath='{.subsets[0].addresses[1].targetRef.name}' \
	endpoints/"${ACCEL_NAME}" -n "${ACCEL_NAMESPACE}" --timeout=1m
for ordinal in 0 1; do
	[[ "$(dockerd wget -q -O - "http://${ACCEL_NAME}-${ordinal}.${ACCEL_NAME}-peers:3128/ca.crt")" == "${generated_ca}" ]]
done
[[ "$("${KUBECTL[@]}" get pod "${ACCEL_NAME}-0" -n "${ACCEL_NAMESPACE}" -o jsonpath='{.metadata.uid}')" == "${proxy_before}" ]]
"${KUBECTL[@]}" delete pod "${ACCEL_NAME}-1" -n "${ACCEL_NAMESPACE}" --wait
dockerd docker image rm "${image}" >/dev/null
dockerd docker pull -q "${image}"
"${KUBECTL[@]}" rollout status statefulset/"${ACCEL_NAME}" -n "${ACCEL_NAMESPACE}" --timeout=3m

# Enable DNS-seeded peering by rolling the existing StatefulSet, without
# replacing its governing Service, runner endpoint or CA.
"${HELM_CLUSTER[@]}" upgrade "${ACCEL_RELEASE}" "${CHART_DIR}" --namespace "${ACCEL_NAMESPACE}" --reuse-values \
	--set ociAccelerator.peering.enabled=true --set ociAccelerator.replicas=2 \
	--set ociAccelerator.networkPolicy.enabled=false \
	--set-string ociAccelerator.extraEnv.OCI_ACCELERATOR_PEER_HINT_REFRESH_INTERVAL=1s >/dev/null
"${KUBECTL[@]}" rollout status statefulset/"${ACCEL_NAME}" -n "${ACCEL_NAMESPACE}" --timeout=3m
[[ -z "$("${KUBECTL[@]}" get deployment "${ACCEL_NAME}" -n "${ACCEL_NAMESPACE}" --ignore-not-found -o name)" ]]
[[ "$("${KUBECTL[@]}" get statefulset "${ACCEL_NAME}" -n "${ACCEL_NAMESPACE}" -o jsonpath='{.metadata.uid}')" == "${accelerator_uid}" ]]
[[ "$("${KUBECTL[@]}" get service "${ACCEL_NAME}-peers" -n "${ACCEL_NAMESPACE}" -o jsonpath='{.metadata.uid}')" == "${headless_uid}" ]]
[[ "$(ca_secret_cert)" == "${generated_ca}" ]]
[[ "$(dockerd wget -q -O - "http://${ACCEL_NAME}:3128/ca.crt")" == "${generated_ca}" ]]

# Give discovery one normal 30-second exchange interval plus jitter. Pull an
# immutable blob through each proxy explicitly so a local cache hit or Service
# load balancing cannot masquerade as peer delivery. Credentials are anonymous.
sleep 40
"${KUBECTL[@]}" run peer-pull -n "${ACCEL_NAMESPACE}" --image=python:3.12-alpine --restart=Never \
	--labels="app.kubernetes.io/name=buildkite-operator,app.kubernetes.io/instance=${ACCEL_RELEASE},app.kubernetes.io/component=runner" \
	--env="CA_CERT=${generated_ca}" --env="PROXY_NAME=${ACCEL_NAME}" --rm -i --quiet --command -- python3 -u -c '
import hashlib
import json
import os
import ssl
import time
import urllib.request

direct = urllib.request.build_opener(urllib.request.ProxyHandler({}))
with direct.open("https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/alpine:pull", timeout=30) as response:
    token = json.load(response)["token"]
headers = {"Authorization": "Bearer " + token, "Accept": "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json"}
base = "https://registry-1.docker.io/v2/library/alpine/"
context = ssl.create_default_context(cadata=os.environ["CA_CERT"])
name = os.environ["PROXY_NAME"]

def fetch(ordinal, path):
    proxy = "http://" + name + "-" + str(ordinal) + "." + name + "-peers:3128"
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({"https": proxy}), urllib.request.HTTPSHandler(context=context))
    with opener.open(urllib.request.Request(base + path, headers=headers), timeout=60) as response:
        return response.read()

index = json.loads(fetch(0, "manifests/3.20"))
digest = next(m["digest"] for m in index["manifests"] if m["platform"].get("architecture") == "amd64" and m["platform"].get("os") == "linux")
manifest = json.loads(fetch(0, "manifests/" + digest))
layer = manifest["layers"][0]["digest"]
for ordinal in (0, 1):
    body = fetch(ordinal, "blobs/" + layer)
    assert "sha256:" + hashlib.sha256(body).hexdigest() == layer
    print("Proxy", ordinal, "served verified blob", layer, "bytes", len(body))
    # Inventory refresh is set to one second for this test.
    time.sleep(3)
'
peer_metrics=$("${KUBECTL[@]}" exec -n "${ACCEL_NAMESPACE}" "${ACCEL_NAME}-1" -c oci-accelerator -- \
	wget -q -O - http://127.0.0.1:9090/metrics)
if ! awk '/^oci_accelerator_served_bytes_total\{.*source="peer"/ && $NF > 0 { found = 1 } END { exit !found }' <<<"${peer_metrics}"; then
	echo "The cold proxy did not serve peer bytes" >&2
	echo "${peer_metrics}" >&2
	exit 1
fi

# Replacement keeps the DNS endpoint but obtains a fresh cache and identity.
"${KUBECTL[@]}" delete pod "${ACCEL_NAME}-1" -n "${ACCEL_NAMESPACE}" --wait
"${KUBECTL[@]}" rollout status statefulset/"${ACCEL_NAME}" -n "${ACCEL_NAMESPACE}" --timeout=3m
"${HELM_CLUSTER[@]}" upgrade "${ACCEL_RELEASE}" "${CHART_DIR}" --namespace "${ACCEL_NAMESPACE}" --reuse-values \
	--set ociAccelerator.replicas=3 --set ociAccelerator.networkPolicy.enabled=true >/dev/null
"${KUBECTL[@]}" rollout status statefulset/"${ACCEL_NAME}" -n "${ACCEL_NAMESPACE}" --timeout=3m
# A peer's TCP connection reaches the TLS listener; a runner cannot reach it.
# Use the Pod IP to isolate policy enforcement from DNS availability. The
# earlier transfer checks already exercise DNS-seeded peer discovery.
peer_ip=$("${KUBECTL[@]}" get pod "${ACCEL_NAME}-2" -n "${ACCEL_NAMESPACE}" -o jsonpath='{.status.podIP}')
"${KUBECTL[@]}" exec -n "${ACCEL_NAMESPACE}" "${ACCEL_NAME}-0" -c oci-accelerator -- \
	nc -z -w 5 "${peer_ip}" 7443
if dockerd nc -z -w 5 "${peer_ip}" 7443; then
	echo "NetworkPolicy admitted a runner to the peer listener" >&2
	exit 1
fi

# Disabling peering keeps independent replicas and the same governing Service.
"${HELM_CLUSTER[@]}" upgrade "${ACCEL_RELEASE}" "${CHART_DIR}" --namespace "${ACCEL_NAMESPACE}" --reuse-values \
	--set ociAccelerator.peering.enabled=false --set ociAccelerator.replicas=2 >/dev/null
"${KUBECTL[@]}" rollout status statefulset/"${ACCEL_NAME}" -n "${ACCEL_NAMESPACE}" --timeout=3m
[[ "$("${KUBECTL[@]}" get statefulset "${ACCEL_NAME}" -n "${ACCEL_NAMESPACE}" -o jsonpath='{.metadata.uid}')" == "${accelerator_uid}" ]]
[[ "$("${KUBECTL[@]}" get service "${ACCEL_NAME}-peers" -n "${ACCEL_NAMESPACE}" -o jsonpath='{.metadata.uid}')" == "${headless_uid}" ]]
[[ "$("${KUBECTL[@]}" get service "${ACCEL_NAME}-peers" -n "${ACCEL_NAMESPACE}" -o jsonpath='{.spec.ports[*].port}')" == "3128" ]]
[[ "$(dockerd wget -q -O - "http://${ACCEL_NAME}:3128/ca.crt")" == "${generated_ca}" ]]
[[ "$(ca_secret_cert)" == "${generated_ca}" ]]

"${HELM_CLUSTER[@]}" uninstall "${ACCEL_RELEASE}" --namespace "${ACCEL_NAMESPACE}" --wait --timeout 2m
for _ in $(seq 1 60); do
	proxy=$(proxy_pod)
	[[ -z "${proxy}" ]] && break
	sleep 1
done
[[ -z "${proxy}" ]] || {
	echo "OCI accelerator Pod remained after uninstall" >&2
	exit 1
}
[[ -z "$("${KUBECTL[@]}" get secret "${ACCEL_CA_SECRET}" -n "${ACCEL_NAMESPACE}" -o name --ignore-not-found)" ]] || {
	echo "Generated CA Secret remained after uninstall" >&2
	exit 1
}
[[ -z "$("${KUBECTL[@]}" get configmap "${ACCEL_CA_CONFIGMAP}" -n "${ACCEL_NAMESPACE}" -o name --ignore-not-found)" ]] || {
	echo "CA ConfigMap remained after uninstall" >&2
	exit 1
}
[[ -z "$("${KUBECTL[@]}" get jobs,roles,serviceaccounts -n "${ACCEL_NAMESPACE}" -l app.kubernetes.io/component=oci-accelerator-ca -o name)" ]] || {
	echo "CA hook resources remained after uninstall" >&2
	exit 1
}
