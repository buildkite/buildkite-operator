#!/usr/bin/env bash
# Exercises the single-use supervisor against a real Docker daemon, using a
# stand-in agent image so no Buildkite token or API is needed.

set -euo pipefail

HELM="${HELM:-helm}"
CHART_DIR="${HELM_CHART_DIR:-charts/buildkite-operator}"
SCRIPT="${CHART_DIR}/files/supervisor.sh"

# Use the chart's own pinned images, as rendered for a single-use runner.
rendered=$("${HELM}" template test "${CHART_DIR}" \
	--api-versions keda.sh/v1alpha1/ScaledObject \
	--api-versions keda.sh/v1alpha1/TriggerAuthentication \
	--set-string runners.queue=test \
	--set runners.maxReplicas=1 \
	--set-string runners.runtime=sysbox \
	--set runners.singleUse=true \
	--set-string agentToken.value=unused)
image_for() { grep -A1 -- "- name: $1\$" <<<"${rendered}" | sed -n 's/^ *image: "\(.*\)"$/\1/p'; }
DIND_IMAGE=$(image_for dockerd)
CLI_IMAGE=$(image_for supervisor)
[[ -n "${DIND_IMAGE}" && -n "${CLI_IMAGE}" ]]
ID="bk-supervisor-test-$$"

cleanup() {
	docker rm --force "${ID}-supervisor" "${ID}-dockerd" >/dev/null 2>&1 || true
	docker volume rm "${ID}-run" "${ID}-workspace" >/dev/null 2>&1 || true
}
trap cleanup EXIT

inner() { docker exec "${ID}-dockerd" docker "$@"; }

wait_for() {
	local description="$1"
	shift
	for _ in $(seq 1 60); do
		if "$@" >/dev/null 2>&1; then
			return 0
		fi
		sleep 1
	done
	echo "Timed out waiting for ${description}" >&2
	docker logs "${ID}-supervisor" >&2 || true
	exit 1
}

agent_name() { inner inspect --format '{{range .Config.Env}}{{println .}}{{end}}' buildkite-agent | sed -n 's/^BUILDKITE_AGENT_NAME=//p'; }
agent_running() { [[ "$(inner inspect --format '{{.State.Running}}' buildkite-agent 2>/dev/null)" == true ]]; }
new_agent_running() { agent_running && [[ "$(agent_name)" != "$1" ]]; }

docker run --detach --privileged --name "${ID}-dockerd" \
	--volume "${ID}-run:/var/run" --volume "${ID}-workspace:/buildkite" \
	"${DIND_IMAGE}" dockerd --host=unix:///var/run/docker.sock >/dev/null
wait_for "Docker daemon" inner info

# The stand-in agent checks the supervisor's arguments, records which agent
# ran the job, and exits once the test releases it.
docker exec -i "${ID}-dockerd" sh -c 'mkdir -p /ctx && cat >/ctx/agent && chmod +x /ctx/agent' <<'EOF'
#!/bin/sh
[ "$*" = "start --disconnect-after-job" ] || { echo "unexpected arguments: $*" >&2; exit 64; }
mkdir -p /buildkite/builds
touch "/buildkite/builds/$BUILDKITE_AGENT_NAME"
until [ -e "/buildkite/release-$BUILDKITE_AGENT_NAME" ]; do sleep 0.2; done
EOF
docker exec -i "${ID}-dockerd" sh -c 'cat >/ctx/Dockerfile && docker build --quiet --tag test-agent:1 /ctx >/dev/null' <<'EOF'
FROM busybox:1.37
COPY agent /usr/local/bin/buildkite-agent
EOF

docker run --detach --read-only --name "${ID}-supervisor" \
	--volume "${ID}-run:/var/run" \
	--volume "$(pwd)/${SCRIPT}:/opt/supervisor/supervisor.sh:ro" \
	--env AGENT_IMAGE=test-agent:1 --env BUILDKITE_AGENT_TOKEN=unused \
	--env AGENT_TAGS=queue=test --env POD_NAME=runner-pod \
	--env TERMINATION_GRACE_PERIOD_SECONDS=20 \
	"${CLI_IMAGE}" /bin/sh /opt/supervisor/supervisor.sh >/dev/null

wait_for "first agent" agent_running
first=$(agent_name)
[[ "${first}" == runner-pod-???? ]]

# Leave state behind as a job would.
inner run --detach --name leftover busybox:1.37 sleep 600 >/dev/null
inner volume create leftover >/dev/null
inner network create leftover >/dev/null
docker exec "${ID}-dockerd" touch /buildkite/builds/leftover-file

docker exec "${ID}-dockerd" touch "/buildkite/release-${first}"
wait_for "replacement agent" new_agent_running "${first}"
second=$(agent_name)

if inner inspect leftover >/dev/null 2>&1 ||
	inner volume inspect leftover >/dev/null 2>&1 ||
	inner network inspect leftover >/dev/null 2>&1; then
	echo "Previous job's container, volume, or network survived" >&2
	exit 1
fi
workspace=$(docker exec "${ID}-dockerd" ls -A /buildkite/builds)
[[ "${workspace}" == "${second}" ]] || {
	echo "Workspace was not reset between jobs: ${workspace}" >&2
	exit 1
}
inner image inspect busybox:1.37 >/dev/null # Image cache is retained.

docker stop --time 30 "${ID}-supervisor" >/dev/null
[[ "$(docker inspect --format '{{.State.ExitCode}}' "${ID}-supervisor")" == 0 ]]
! agent_running

echo "Supervisor ran fresh agents for each job and cleaned state between them"
