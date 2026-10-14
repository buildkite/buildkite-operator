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
# The first release serves four queues to verify entries stay independent.
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

# Installs a release with one queue entry per remaining argument, each named
# after and serving the queue of the same name. Arguments after -- are passed
# to Helm.
install_runner_chart() {
	local release="$1"
	local namespace="$2"
	shift 2
	local args=()
	while [[ $# -gt 0 && "$1" != -- ]]; do
		args+=(--set-string "queues.$1.queue=$1" --set "queues.$1.maxReplicas=1")
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
	rm -rf "${agent_dir:-}" "${agent_logs:-}"
}
trap cleanup EXIT

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
	--set-string queues.e2e-dind.runtime=dind \
	--set-string queues.e2e-dind.docker.resources.requests.cpu=100m \
	--set-string queues.e2e-dind.docker.resources.requests.memory=256Mi \
	--set-string queues.e2e-dind.docker.resources.requests.ephemeral-storage=1Gi \
	--set queues.e2e-ephemeral.ephemeralAgent=true \
	--set-string queues.e2e-ephemeral.image.repository=busybox \
	--set-string queues.e2e-ephemeral.image.tag=1.37 \
	--set queues.e2e-ephemeral.terminationGracePeriodSeconds=30
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

# Ephemeral standard agents: each job gets a newly registered agent and a clean
# workspace while the container keeps running.
ephemeral_pod=""
for _ in $(seq 1 60); do
	ephemeral_pod=$(runner_pods "${NAMESPACE}" e2e-ephemeral)
	[[ -n "${ephemeral_pod}" ]] && break
	sleep 1
done
[[ -n "${ephemeral_pod}" ]] || { echo "The ephemeral queue entry did not create a runner Pod" >&2; exit 1; }
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
[[ -n "${dind_pod}" ]] || { echo "The dind queue entry did not create a runner Pod" >&2; exit 1; }
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
	--set-string queues.accel.queue=accel \
	--set-string queues.accel.runtime=dind \
	--set queues.accel.maxReplicas=1 \
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
"${KUBECTL[@]}" rollout status deployment/"${ACCEL_NAME}" -n "${ACCEL_NAMESPACE}" --timeout=3m

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

# Runner Pods take the certificate from the ConfigMap. The kubelet can read
# every key of a Secret a Pod on its node references, so they must not
# reference the CA Secret.
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

# Upgrades keep the generated CA, and one that leaves the proxy unchanged keeps
# its Pod and so its cache. Releases installed before the chart published the
# certificate have no ConfigMap, so upgrades create it from the Secret.
proxy_pod() {
	"${KUBECTL[@]}" get pods -n "${ACCEL_NAMESPACE}" -l app.kubernetes.io/component=oci-accelerator -o name
}
proxy_before=$(proxy_pod)
"${KUBECTL[@]}" delete configmap "${ACCEL_CA_CONFIGMAP}" -n "${ACCEL_NAMESPACE}"
"${HELM_CLUSTER[@]}" upgrade "${ACCEL_RELEASE}" "${CHART_DIR}" --namespace "${ACCEL_NAMESPACE}" --reuse-values
[[ "$(ca_secret_cert)" == "${generated_ca}" ]] || { echo "helm upgrade replaced the generated CA" >&2; exit 1; }
[[ "$(ca_configmap_cert)" == "${generated_ca}" ]] || { echo "helm upgrade did not recreate the CA ConfigMap" >&2; exit 1; }
[[ "$(proxy_pod)" == "${proxy_before}" ]] || { echo "helm upgrade replaced the unchanged proxy Pod" >&2; exit 1; }

# A second pull of a removed image is served from the cache.
image=public.ecr.aws/docker/library/alpine:3.20
dockerd docker pull -q "${image}"
dockerd docker image rm "${image}" >/dev/null
dockerd docker pull -q "${image}"
accelerator_logs=$("${KUBECTL[@]}" logs deployment/"${ACCEL_NAME}" -n "${ACCEL_NAMESPACE}" -c oci-accelerator)
# Not grep -q: exiting at the first match would fail the pipeline with SIGPIPE.
if ! grep '"registry":"public.ecr.aws"' <<<"${accelerator_logs}" | grep '"cache":"hit"' >/dev/null; then
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
