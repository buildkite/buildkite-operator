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

# Print the rendered document of the given kind and name.
document() {
	awk -v kind="$2" -v name="$3" '
		/^---$/ { if (doc ~ "\nkind: " kind "\n" && doc ~ "\n  name: " name "\n") printf "%s", doc; doc = "\n"; next }
		{ doc = doc $0 "\n" }
		END { if (doc ~ "\nkind: " kind "\n" && doc ~ "\n  name: " name "\n") printf "%s", doc }' <<<"$1"
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
assert_contains "${direct}" 'buildkite.com/runner-pool: "linux"'
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
assert_contains "${direct}" "value: /buildkite/plugins"
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
if [[ "${direct}" == *"ephemeral-agent"* ]]; then
	echo "Persistent agents rendered the ephemeral agent loop" >&2
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
	echo "Persistent agents rendered the ephemeral-agent supervisor" >&2
	exit 1
fi

# dind runs the same Docker daemon sidecar, privileged and without a
# RuntimeClass, node selector or toleration, so it schedules on any node.
dind=$(render --set-string agentToken.value="${TOKEN}" --set-string queues.linux.runtime=dind)
dind_runner=$(document "${dind}" Deployment test-linux)
assert_contains "${dind_runner}" "- name: dockerd"
assert_contains "${dind_runner}" $'securityContext:\n            privileged: true'
assert_contains "${dind_runner}" "- name: agent"
assert_contains "${dind_runner}" 'value: "queue=linux,runtime=dind"'
assert_contains "${dind_runner}" "value: unix:///var/run/docker.sock"
assert_contains "${dind_runner}" "- name: docker-data"
assert_contains "${dind_runner}" 'cluster-autoscaler.kubernetes.io/safe-to-evict: "false"'
for unexpected in "runtimeClassName:" "nodeSelector:" "tolerations:" "hostUsers:" "--storage-driver" "- name: supervisor"; do
	if [[ "${dind_runner}" == *"${unexpected}"* ]]; then
		echo "dind runners rendered ${unexpected}" >&2
		exit 1
	fi
done
ephemeral_dind=$(render --set-string agentToken.value="${TOKEN}" --set-string queues.linux.runtime=dind --set queues.linux.ephemeralAgent=true)
ephemeral_dind_runner=$(document "${ephemeral_dind}" Deployment test-linux)
assert_contains "${ephemeral_dind_runner}" "- name: supervisor"
assert_contains "${ephemeral_dind_runner}" "- name: dockerd"
assert_contains "${ephemeral_dind_runner}" "checksum/supervisor:"
if [[ "${ephemeral_dind_runner}" == *"- name: agent"* || "${ephemeral_dind_runner}" == *"runtimeClassName:"* ]]; then
	echo "Ephemeral dind agents rendered an agent container or RuntimeClass" >&2
	exit 1
fi
[[ $(grep -c 'privileged: true' <<<"${ephemeral_dind_runner}") -eq 1 ]] || {
	echo "Only the dind Docker daemon should be privileged" >&2
	exit 1
}

ephemeral=$(render --set-string agentToken.value="${TOKEN}" --set-string queues.linux.runtime=sysbox --set queues.linux.ephemeralAgent=true)
assert_contains "${ephemeral}" "- name: supervisor"
assert_contains "${ephemeral}" 'command: ["/bin/sh", "/opt/ephemeral-agent/supervisor.sh"]'
assert_contains "${ephemeral}" "name: test-buildkite-operator-ephemeral-agent"
assert_contains "${ephemeral}" 'image: "docker:29.7.2-cli@sha256:3f4743208d2338c934d7b8bcfbe1bb54c0b2355c510ad5e0f31c0c4a54bd704e"'
assert_contains "${ephemeral}" 'value: "buildkite/agent:4"'
assert_contains "${ephemeral}" "checksum/supervisor:"
assert_contains "${ephemeral}" "start --disconnect-after-job"
assert_contains "${ephemeral}" "- name: dockerd"
if [[ "${ephemeral}" == *"- name: agent"* || "${ephemeral}" == *"checksum/ephemeral-agent:"* ]]; then
	echo "Ephemeral sysbox agents also rendered an agent container" >&2
	exit 1
fi
ephemeral_kata=$(render --set-string agentToken.value="${TOKEN}" --set-string queues.linux.runtime=kata --set queues.linux.ephemeralAgent=true)
assert_contains "${ephemeral_kata}" "runtimeClassName: kata-qemu-runtime-rs"
assert_contains "${ephemeral_kata}" "- name: supervisor"

# Standard ephemeral agents restart in a loop inside the agent container, which
# keeps the agent's own resources.
ephemeral_standard=$(render --set-string agentToken.value="${TOKEN}" --set queues.linux.ephemeralAgent=true \
	--set-string queues.linux.resources.limits.memory=2Gi)
standard_runner=$(document "${ephemeral_standard}" Deployment test-linux)
assert_contains "${standard_runner}" "- name: agent"
assert_contains "${standard_runner}" 'command: ["/bin/sh", "/opt/ephemeral-agent/ephemeral-agent.sh"]'
assert_contains "${standard_runner}" "checksum/ephemeral-agent:"
assert_contains "${standard_runner}" 'value: "queue=linux,runtime=standard"'
assert_contains "${standard_runner}" "value: /buildkite/plugins"
assert_contains "${standard_runner}" "memory: 2Gi"
assert_contains "${standard_runner}" $'- name: ephemeral-agent-scripts\n              mountPath: /opt/ephemeral-agent'
assert_contains "${standard_runner}" 'cluster-autoscaler.kubernetes.io/safe-to-evict: "false"'
assert_contains "${standard_runner}" "- name: deletion-cost"
assert_contains "${ephemeral_standard}" "start --disconnect-after-job"
assert_contains "${ephemeral_standard}" 'clean_workspace() {'
for unexpected in "- name: supervisor" "- name: dockerd" "checksum/supervisor:" 'args: ["start"]' "runtimeClassName:"; do
	if [[ "${standard_runner}" == *"${unexpected}"* ]]; then
		echo "Standard ephemeral agents rendered ${unexpected}" >&2
		exit 1
	fi
done
# The workspace wipe would be unbounded without these paths.
for env in BUILDKITE_AGENT_NAME BUILDKITE_BUILD_PATH BUILDKITE_PLUGINS_PATH; do
	assert_contains "${standard_runner}" "- name: ${env}"
done
inherited=$(render --set-string agentToken.value="${TOKEN}" --set defaults.ephemeralAgent=true)
assert_contains "${inherited}" 'command: ["/bin/sh", "/opt/ephemeral-agent/ephemeral-agent.sh"]'

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
	--set queues.build-sysbox.ephemeralAgent=true \
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
kata_runner=$(document "${multi}" Deployment test-linux-kata)
sysbox_runner=$(document "${multi}" Deployment test-build-sysbox)
assert_contains "${kata_runner}" "runtimeClassName: kata-qemu-runtime-rs"
assert_contains "${kata_runner}" "- name: agent"
assert_contains "${kata_runner}" 'value: "queue=linux,runtime=kata"'
assert_contains "${kata_runner}" 'buildkite.com/runner-pool: "linux-kata"'
assert_contains "${kata_runner}" "memory: 8Gi"
assert_contains "${sysbox_runner}" "runtimeClassName: sysbox-runc"
assert_contains "${sysbox_runner}" "- name: supervisor"
assert_contains "${sysbox_runner}" 'value: "queue=build,runtime=sysbox"'
assert_contains "${sysbox_runner}" 'buildkite.com/runner-pool: "build-sysbox"'
assert_contains "${sysbox_runner}" "memory: 16Gi"
assert_contains "${sysbox_runner}" 'cpu: "4"' # Inherited alongside the memory override.
# Each Deployment must select only its own entry's Pods; otherwise a release's
# Deployments would adopt each other's runners.
for entry in linux-kata build-sysbox; do
	selector=$(document "${multi}" Deployment "test-${entry}" | awk '/^  selector:$/ { found = 1; next } found && /^  [^ ]/ { found = 0 } found { print }')
	assert_contains "${selector}" "buildkite.com/runner-pool: \"${entry}\""
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
assert_contains "${multi}" "name: test-buildkite-operator-ephemeral-agent"

# The OCI accelerator serves Docker-backed entries that have not opted out.
accel_args=(
	--set-string agentToken.value="${TOKEN}"
	--set ociAccelerator.enabled=true
	--set-string ociAccelerator.ca.existingSecret.name=oci-ca
)
if [[ "${kata}" == *"oci-accelerator"* ]]; then
	echo "OCI accelerator rendered while disabled" >&2
	exit 1
fi
accel=$(render "${accel_args[@]}" --set-string queues.linux.runtime=sysbox \
	--set ociAccelerator.noProxy='{registry.internal:5000}' \
	--set-string ociAccelerator.extraEnv.OCI_ACCELERATOR_CACHE_MAX_FILLS=32)
for kind in Service NetworkPolicy; do
	[[ $(count_kind "${accel}" "${kind}") -eq 1 ]] || { echo "Expected one OCI accelerator ${kind}" >&2; exit 1; }
done
[[ $(count_kind "${accel}" Deployment) -eq 2 ]] || { echo "Expected a runner and an OCI accelerator Deployment" >&2; exit 1; }
if [[ "${accel}" == *"kind: StatefulSet"* || "${accel}" == *"PersistentVolumeClaim"* || "${accel}" == *"volumeClaimTemplates"* ]]; then
	echo "OCI accelerator rendered persistent storage" >&2
	exit 1
fi
accel_runner=$(document "${accel}" Deployment test-linux)
assert_contains "${accel_runner}" "- --https-proxy=http://test-buildkite-operator-oci-accelerator.buildkite-runners.svc:3128"
assert_contains "${accel_runner}" "- --no-proxy=registry.internal:5000"
assert_contains "${accel_runner}" $'- name: SSL_CERT_DIR\n              value: /etc/ssl/certs:/etc/ssl/oci-accelerator-certs'
assert_contains "${accel_runner}" $'secretName: "oci-ca"\n            items:\n              - key: "ca.crt"\n                path: ca.crt'
if [[ "${accel_runner}" == *'"ca.key"'* ]]; then
	echo "Runner Pods mounted the OCI accelerator private key" >&2
	exit 1
fi
accel_proxy=$(document "${accel}" Deployment test-buildkite-operator-oci-accelerator)
assert_contains "${accel_proxy}" 'image: "buildkite/oci-accelerator:v0.2.1@sha256:a26eb344cc4858ccd63a92150a7deaf11766e3a5155add2c00e4dad4a5fec6cf"'
assert_contains "${accel_proxy}" 'value: "registry-1.docker.io,ghcr.io,public.ecr.aws"'
assert_contains "${accel_proxy}" $'OCI_ACCELERATOR_CACHE_MAX_FILLS\n              value: "32"'
assert_contains "${accel_proxy}" $'- name: cache\n          emptyDir:\n            sizeLimit: 20Gi'
assert_contains "${accel_proxy}" $'OCI_ACCELERATOR_CACHE_MAX_BYTES\n              value: "19327352832"'
assert_contains "${accel_proxy}" $'maxSurge: 1\n      maxUnavailable: 0'
assert_contains "${accel_proxy}" $'requests:\n              cpu: 500m\n              ephemeral-storage: 20Gi\n              memory: 512Mi'
# A request set in resources is kept, and limits are untouched.
accel_storage=$(document "$(render "${accel_args[@]}" --set-string queues.linux.runtime=kata \
	--set-string ociAccelerator.cache.size=8Gi --set ociAccelerator.cache.maxBytes=7516192768 \
	--set-string ociAccelerator.resources.requests.ephemeral-storage=12Gi)" Deployment test-buildkite-operator-oci-accelerator)
assert_contains "${accel_storage}" "sizeLimit: 8Gi"
assert_contains "${accel_storage}" "ephemeral-storage: 12Gi"
assert_contains "${accel_storage}" $'limits:\n              memory: 2Gi'
assert_contains "${accel_proxy}" $'path: ca.key\n'
assert_contains "$(document "${accel}" NetworkPolicy test-buildkite-operator-oci-accelerator)" "app.kubernetes.io/component: runner"
accel_dind=$(document "$(render "${accel_args[@]}" --set-string queues.linux.runtime=dind)" Deployment test-linux)
assert_contains "${accel_dind}" "- --https-proxy=http://test-buildkite-operator-oci-accelerator.buildkite-runners.svc:3128"
assert_contains "${accel_dind}" $'- name: SSL_CERT_DIR\n              value: /etc/ssl/certs:/etc/ssl/oci-accelerator-certs'
if [[ "${accel_dind}" == *'"ca.key"'* ]]; then
	echo "dind runner Pods mounted the OCI accelerator private key" >&2
	exit 1
fi
no_policy=$(render "${accel_args[@]}" --set-string queues.linux.runtime=kata --set ociAccelerator.networkPolicy.enabled=false)
[[ $(count_kind "${no_policy}" NetworkPolicy) -eq 0 ]] || { echo "NetworkPolicy rendered while disabled" >&2; exit 1; }
# Entries without a Docker daemon or that opt out pull directly, and with no
# entry using it the accelerator is not installed.
accel_opt_out=$("${HELM}" template test "${CHART_DIR}" "${KEDA_API_VERSIONS[@]}" "${accel_args[@]}" \
	--set-string queues.std.queue=std --set queues.std.maxReplicas=1 \
	--set-string queues.kata.queue=kata --set-string queues.kata.runtime=kata --set queues.kata.maxReplicas=1 \
	--set queues.kata.docker.ociAccelerator=false)
if [[ "${accel_opt_out}" == *"oci-accelerator"* || "${accel_opt_out}" == *"https-proxy"* ]]; then
	echo "OCI accelerator rendered with no entry using it" >&2
	exit 1
fi
[[ $(count_kind "${accel}" Job) -eq 0 ]] || { echo "CA hook Jobs rendered with an existing CA Secret" >&2; exit 1; }
if [[ "${accel}" == *"oci-accelerator-ca\""* ]]; then
	echo "Generated CA Secret referenced with an existing CA Secret" >&2
	exit 1
fi
# The proxy loads the CA only from the Secret, so it never generates its own:
# an existing CA directory stops it from initializing one.
assert_contains "${accel_proxy}" "cp /ca-source/ca.crt /ca-source/ca.key /run/oci-accelerator/private/ca/"
assert_contains "${accel_proxy}" $'- name: ca-source\n          secret:\n            secretName: "oci-ca"'
assert_contains "${accel_proxy}" $'OCI_ACCELERATOR_CA_DIR\n              value: /run/oci-accelerator/private/ca'

# Without an existing Secret, hook Jobs generate the CA with init-ca before
# install and upgrade, and delete its Secret after uninstall.
generated=$(render --set-string agentToken.value="${TOKEN}" --set ociAccelerator.enabled=true \
	--set-string queues.linux.runtime=dind)
generated_secret="test-buildkite-operator-oci-accelerator-ca"
assert_contains "$(document "${generated}" Deployment test-buildkite-operator-oci-accelerator)" "secretName: \"${generated_secret}\""
assert_contains "$(document "${generated}" Deployment test-linux)" "secretName: \"${generated_secret}\""
[[ $(count_kind "${generated}" Job) -eq 2 ]] || { echo "Expected two CA hook Jobs" >&2; exit 1; }
ca_create=$(document "${generated}" Job test-buildkite-operator-oci-accelerator-ca-create)
assert_contains "${ca_create}" "helm.sh/hook: pre-install,pre-upgrade"
assert_contains "${ca_create}" "oci-accelerator init-ca --dir /work/state/ca"
assert_contains "${ca_create}" 'image: "buildkite/oci-accelerator:v0.2.1@sha256:a26eb344cc4858ccd63a92150a7deaf11766e3a5155add2c00e4dad4a5fec6cf"'
assert_contains "${ca_create}" $'SECRET_NAME\n              value: "'"${generated_secret}"'"'
ca_delete=$(document "${generated}" Job test-buildkite-operator-oci-accelerator-ca-delete)
assert_contains "${ca_delete}" "helm.sh/hook: post-delete"
assert_contains "${ca_delete}" '"/opt/oci-accelerator-ca/oci_accelerator_ca.py", "delete"'
if [[ "${ca_delete}" == *"init-ca"* ]]; then
	echo "CA delete Job generated a CA" >&2
	exit 1
fi
ca_role=$(document "${generated}" Role test-buildkite-operator-oci-accelerator-ca-hook)
assert_contains "${ca_role}" "helm.sh/hook: pre-install,pre-upgrade,post-delete"
assert_contains "${ca_role}" $'resourceNames: ["'"${generated_secret}"$'"]\n    verbs: ["get", "delete"]'
for kind in ServiceAccount RoleBinding ConfigMap; do
	assert_contains "$(document "${generated}" "${kind}" test-buildkite-operator-oci-accelerator-ca-hook)" \
		"helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded"
done
if [[ $(count_kind "${generated}" Secret) -ne 1 || "$(document "${generated}" Secret "${generated_secret}")" != "" ]]; then
	echo "The chart rendered the CA Secret itself" >&2
	exit 1
fi
if [[ "${accel_opt_out}" == *"ca-create"* ]]; then
	echo "CA hook Jobs rendered with no entry using the accelerator" >&2
	exit 1
fi
assert_fails "ociAccelerator.noProxy must not include ghcr.io:443" \
	--set-string queues.linux.queue=linux --set queues.linux.maxReplicas=1 --set-string queues.linux.runtime=kata \
	"${accel_args[@]}" --set ociAccelerator.noProxy='{ghcr.io:443}'
assert_fails "ociAccelerator.extraEnv.OCI_ACCELERATOR_LISTEN is managed by the chart" \
	--set-string queues.linux.queue=linux --set queues.linux.maxReplicas=1 --set-string queues.linux.runtime=kata \
	"${accel_args[@]}" --set-string ociAccelerator.extraEnv.OCI_ACCELERATOR_LISTEN=0.0.0.0:1
assert_fails "does not match pattern" \
	--set-string queues.linux.queue=linux --set queues.linux.maxReplicas=1 \
	"${accel_args[@]}" --set ociAccelerator.registries='{https://ghcr.io}'

# Docker runners always share a writable Docker client configuration for the
# Pod's lifetime; standard runners have none.
docker_config_mount=$'- name: docker-config\n              mountPath: /etc/buildkite-agent/docker'
docker_config_env=$'- name: DOCKER_CONFIG\n              value: /etc/buildkite-agent/docker'
assert_contains "${dind_runner}" "${docker_config_env}"
assert_contains "$(awk '/^        - name: agent$/,/^        - name: deletion-cost$/' <<<"${dind_runner}")" "${docker_config_mount}"
supervisor_container=$(awk '/^        - name: supervisor$/,/^        - name: deletion-cost$/' <<<"${ephemeral_dind_runner}")
assert_contains "${supervisor_container}" "${docker_config_env}"
assert_contains "${supervisor_container}" "${docker_config_mount}"
assert_contains "$(awk '/^        - name: dockerd$/,/^      containers:$/' <<<"${ephemeral_dind_runner}")" "${docker_config_mount}"
assert_contains "${ephemeral}" '--volume "$DOCKER_CONFIG:$DOCKER_CONFIG"'
for runner in "${dind_runner}" "${ephemeral_dind_runner}"; do
	assert_contains "${runner}" $'- name: docker-config\n          emptyDir:\n            sizeLimit: 16Mi'
	for unexpected in "imagePullSecrets:" "registry-credentials"; do
		if [[ "${runner}" == *"${unexpected}"* ]]; then
			echo "Runners without registry credentials rendered ${unexpected}" >&2
			exit 1
		fi
	done
done
if [[ "$(document "${direct}" Deployment test-linux)" == *"docker-config"* || "${direct}" == *"DOCKER_CONFIG"* ]]; then
	echo "Standard runners rendered a Docker client configuration" >&2
	exit 1
fi

# Persistent Docker runners copy the agent binary into the workspace, which the
# Docker daemon shares, so jobs can bind-mount it; the supervisor does the same
# for ephemeral agents.
agent_binary_env=$'- name: BUILDKITE_AGENT_BINARY_PATH\n              value: /buildkite/bin/buildkite-agent'
dind_init=$(awk '/^      initContainers:$/,/^      containers:$/' <<<"${dind_runner}")
assert_contains "${dind_init}" $'- name: agent-binary\n          image: "buildkite/agent:4"'
assert_contains "${dind_init}" 'cp /usr/local/bin/buildkite-agent /buildkite/bin/buildkite-agent'
assert_contains "$(awk '/^        - name: agent$/,/^        - name: deletion-cost$/' <<<"${dind_runner}")" "${agent_binary_env}"
assert_contains "${ephemeral}" '--env BUILDKITE_AGENT_BINARY_PATH=/buildkite/bin/buildkite-agent'
if [[ "${ephemeral_dind_runner}" == *"- name: agent-binary"* || "${direct}" == *"BUILDKITE_AGENT_BINARY_PATH"* ]]; then
	echo "Ephemeral Docker or standard runners rendered the agent binary copy" >&2
	exit 1
fi

# Registry credentials become one dockerconfigjson Secret, used to pull every
# Pod's images and copied into Docker runners' client configuration.
credential_args=(
	--set-string agentToken.value="${TOKEN}"
	--set-string 'registryCredentials.auths[0].registry=https://index.docker.io/v1/'
	--set-string 'registryCredentials.auths[0].username=hub-user'
	--set-string 'registryCredentials.auths[0].password=hub-token'
	--set-string 'registryCredentials.auths[1].registry=ghcr.io'
	--set-string 'registryCredentials.auths[1].username=gh-user'
	--set-string 'registryCredentials.auths[1].password=gh-token'
)
credentials=$("${HELM}" template test "${CHART_DIR}" --namespace buildkite-runners "${KEDA_API_VERSIONS[@]}" \
	"${credential_args[@]}" --set ociAccelerator.enabled=true \
	--set-string queues.std.queue=std --set queues.std.maxReplicas=1 \
	--set-string queues.per.queue=per --set-string queues.per.runtime=dind --set queues.per.maxReplicas=1 \
	--set-string queues.eph.queue=eph --set-string queues.eph.runtime=sysbox --set queues.eph.ephemeralAgent=true \
	--set queues.eph.maxReplicas=1)
credentials_secret=$(document "${credentials}" Secret test-buildkite-operator-registry-credentials)
assert_contains "${credentials_secret}" "type: kubernetes.io/dockerconfigjson"
dockerconfigjson=$(sed -n 's/^  \.dockerconfigjson: //p' <<<"${credentials_secret}" | base64 --decode)
expected_config='{"auths":{"ghcr.io":{"auth":"'"$(printf 'gh-user:gh-token' | base64)"'","password":"gh-token","username":"gh-user"},"https://index.docker.io/v1/":{"auth":"'"$(printf 'hub-user:hub-token' | base64)"'","password":"hub-token","username":"hub-user"}}}'
[[ "${dockerconfigjson}" == "${expected_config}" ]] || {
	echo "Unexpected .dockerconfigjson: ${dockerconfigjson}" >&2
	exit 1
}
pull_secret=$'imagePullSecrets:\n        - name: "test-buildkite-operator-registry-credentials"'
for deployment in test-std test-per test-eph test-buildkite-operator-oci-accelerator; do
	assert_contains "$(document "${credentials}" Deployment "${deployment}")" "${pull_secret}"
	assert_contains "$(document "${credentials}" Deployment "${deployment}")" "checksum/registry-credentials:"
done
# Hooks run before the release's Secret exists on install and after it is
# deleted on uninstall, so they pull with a copy that exists only while they run.
hook_secret=$(document "${credentials}" Secret test-buildkite-operator-registry-credentials-hook)
assert_contains "${hook_secret}" "helm.sh/hook: pre-install,pre-upgrade,post-delete"
assert_contains "${hook_secret}" 'helm.sh/hook-weight: "-20"'
assert_contains "${hook_secret}" "helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded,hook-failed"
assert_contains "${hook_secret}" "type: kubernetes.io/dockerconfigjson"
[[ "$(sed -n 's/^  \.dockerconfigjson: //p' <<<"${hook_secret}" | base64 --decode)" == "${expected_config}" ]] || {
	echo "Hook registry credentials Secret differs from the release's" >&2
	exit 1
}
if [[ "${credentials_secret}" == *"helm.sh/hook"* ]]; then
	echo "The release's registry credentials Secret was rendered as a hook" >&2
	exit 1
fi
for job in create delete; do
	assert_contains "$(document "${credentials}" Job "test-buildkite-operator-oci-accelerator-ca-${job}")" \
		$'imagePullSecrets:\n        - name: "test-buildkite-operator-registry-credentials-hook"'
done
# Without hook Jobs, there is no hook copy.
for no_hooks in \
	"$(render "${credential_args[@]}" --set-string queues.linux.runtime=dind)" \
	"$(render "${credential_args[@]}" --set-string queues.linux.runtime=dind --set ociAccelerator.enabled=true \
		--set-string ociAccelerator.ca.existingSecret.name=oci-ca)"; do
	if [[ "${no_hooks}" == *"registry-credentials-hook"* ]]; then
		echo "Hook registry credentials Secret rendered without hook Jobs" >&2
		exit 1
	fi
done
credentials_std=$(document "${credentials}" Deployment test-std)
if [[ "${credentials_std}" == *"docker-config"* || "${credentials_std}" == *"- name: registry-credentials"* ]]; then
	echo "Standard runners received Docker client credentials" >&2
	exit 1
fi
copy_command='command: ["cp", "/registry-credentials/config.json", "/etc/buildkite-agent/docker/config.json"]'
for deployment in test-per test-eph; do
	credentials_runner=$(document "${credentials}" Deployment "${deployment}")
	assert_contains "${credentials_runner}" $'initContainers:\n        # Copied rather than mounted so jobs can still docker login and keep\n        # buildx state alongside the credentials.\n        - name: docker-config'
	assert_contains "${credentials_runner}" "${copy_command}"
	assert_contains "${credentials_runner}" $'secretName: "test-buildkite-operator-registry-credentials"\n            items:\n              - key: .dockerconfigjson\n                path: config.json'
done
rotated_credentials=$(render "${credential_args[@]}" --set-string 'registryCredentials.auths[1].password=rotated')
if [[ $(grep 'checksum/registry-credentials:' <<<"${credentials_std}") == $(grep 'checksum/registry-credentials:' <<<"${rotated_credentials}") ]]; then
	echo "Registry credential rotation did not change the Pod template" >&2
	exit 1
fi
existing_credentials=$(render --set-string agentToken.value="${TOKEN}" --set-string queues.linux.runtime=kata \
	--set-string registryCredentials.existingSecret.name=hub-pull)
assert_contains "${existing_credentials}" $'imagePullSecrets:\n        - name: "hub-pull"'
assert_contains "${existing_credentials}" $'secretName: "hub-pull"\n            items:\n              - key: .dockerconfigjson'
assert_contains "${existing_credentials}" "${copy_command}"
if [[ "${existing_credentials}" == *"checksum/registry-credentials:"* || "${existing_credentials}" == *"kubernetes.io/dockerconfigjson"* ]]; then
	echo "Existing registry credentials Secret mode rendered a Secret or checksum" >&2
	exit 1
fi
# An existing Secret is created before install, so hooks use it directly.
existing_credentials_hooks=$(render --set-string agentToken.value="${TOKEN}" --set-string queues.linux.runtime=dind \
	--set ociAccelerator.enabled=true --set-string registryCredentials.existingSecret.name=hub-pull)
assert_contains "$(document "${existing_credentials_hooks}" Job test-buildkite-operator-oci-accelerator-ca-create)" \
	$'imagePullSecrets:\n        - name: "hub-pull"'
if [[ "${existing_credentials_hooks}" == *"registry-credentials-hook"* || "${existing_credentials_hooks}" == *"kubernetes.io/dockerconfigjson"* ]]; then
	echo "Existing registry credentials Secret mode rendered a hook Secret" >&2
	exit 1
fi
assert_fails "set only one of registryCredentials.auths or registryCredentials.existingSecret.name" \
	--set-string queues.linux.queue=linux --set queues.linux.maxReplicas=1 \
	"${credential_args[@]}" --set-string registryCredentials.existingSecret.name=hub-pull
assert_fails "registryCredentials.auths lists registry ghcr.io more than once" \
	--set-string queues.linux.queue=linux --set queues.linux.maxReplicas=1 \
	"${credential_args[@]}" --set-string 'registryCredentials.auths[0].registry=ghcr.io'
assert_fails "missing property 'password'" \
	--set-string queues.linux.queue=linux --set queues.linux.maxReplicas=1 \
	--set-string agentToken.value="${TOKEN}" \
	--set-string 'registryCredentials.auths[0].registry=ghcr.io' \
	--set-string 'registryCredentials.auths[0].username=gh-user'

# Entry names that YAML would read as numbers or booleans stay strings, as
# Kubernetes label values must be.
numeric=$("${HELM}" template test "${CHART_DIR}" \
	"${KEDA_API_VERSIONS[@]}" \
	--set-string agentToken.value="${TOKEN}" \
	--set-string queues.123.queue=linux \
	--set queues.123.maxReplicas=1 \
	--set-string queues.true.queue=build \
	--set queues.true.maxReplicas=1)
[[ $(grep -c 'buildkite.com/runner-pool: "123"$' <<<"${numeric}") -eq 4 ]] || {
	echo "Numeric entry name was not quoted in every runner-pool label" >&2
	exit 1
}
[[ $(grep -c 'buildkite.com/runner-pool: "true"$' <<<"${numeric}") -eq 4 ]] || {
	echo "Boolean-like entry name was not quoted in every runner-pool label" >&2
	exit 1
}

# A later values file can override or remove a single queue entry.
values_dir=$(mktemp -d)
trap 'rm -rf "${values_dir}"' EXIT
cat >"${values_dir}/base.yaml" <<EOF
agentToken: {value: ${TOKEN}}
queues:
  linux-kata: {queue: linux, runtime: kata, maxReplicas: 10}
  build-sysbox: {queue: build, runtime: sysbox, ephemeralAgent: true, maxReplicas: 4}
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
if [[ "${overridden}" == *"name: test-buildkite-operator-ephemeral-agent"* ]]; then
	echo "Ephemeral agent ConfigMap rendered with no ephemeral queue" >&2
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
assert_contains "${runtime_notes}" "build-sysbox: queue build, sysbox, ephemeral agents, 1-4 runners"
accel_notes=$(notes -f "${values_dir}/base.yaml" --set ociAccelerator.enabled=true \
	--set-string ociAccelerator.ca.existingSecret.name=oci-ca --set queues.build-sysbox.docker.ociAccelerator=false)
assert_contains "${accel_notes}" "Docker daemons for linux-kata pull through the OCI accelerator"
assert_contains "${accel_notes}" "kubectl logs deployment/test-buildkite-operator-oci-accelerator"
unused_accel_notes=$(notes --set ociAccelerator.enabled=true --set-string queues.linux.queue=linux --set queues.linux.maxReplicas=1)
assert_contains "${unused_accel_notes}" "no dind, kata or sysbox queue entry uses it"
standard_notes=$(notes --set-string queues.linux.queue=linux --set queues.linux.maxReplicas=1)
assert_contains "${standard_notes}" "linux: queue linux, standard, persistent agents, 1-1 runners"
if [[ "${standard_notes}" == *"RuntimeClass"* || "${standard_notes}" == *"privileged"* ]]; then
	echo "NOTES listed runtime prerequisites for a standard-only release" >&2
	exit 1
fi
assert_contains "${runtime_notes}" 'kata runner Pods include a privileged Docker daemon, so the namespace must allow privileged Pods (Pod Security Admission level "privileged")'
dind_notes=$(notes --set-string queues.docker.queue=docker --set queues.docker.maxReplicas=1 --set-string queues.docker.runtime=dind)
assert_contains "${dind_notes}" "docker: queue docker, dind, persistent agents"
assert_contains "${dind_notes}" "dind runner Pods include a privileged Docker daemon"
assert_contains "${dind_notes}" "WARNING: dind needs nothing installed"
assert_contains "${dind_notes}" "only run trusted jobs on dind queues"
if [[ "${dind_notes}" == *"RuntimeClass"* ]]; then
	echo "NOTES listed RuntimeClass prerequisites for a dind-only release" >&2
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
assert_fails "value must be one of 'standard', 'dind', 'kata', 'sysbox'" \
	--set-string queues.linux.queue=linux \
	--set queues.linux.maxReplicas=1 \
	--set-string queues.linux.runtime=gvisor \
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
