#!/usr/bin/env bash
# Exercises the ephemeral-agent supervisor against a real Docker daemon, using a
# stand-in agent image so no Buildkite token or API is needed.

set -euo pipefail

HELM="${HELM:-helm}"
CHART_DIR="${HELM_CHART_DIR:-charts/buildkite-operator}"
SCRIPT="${CHART_DIR}/files/supervisor.sh"

# Use the chart's own pinned images, as rendered for an ephemeral sysbox runner.
rendered=$("${HELM}" template test "${CHART_DIR}" \
	--api-versions keda.sh/v1alpha1/ScaledObject \
	--api-versions keda.sh/v1alpha1/TriggerAuthentication \
	--set-string queues.test.queue=test \
	--set queues.test.maxReplicas=1 \
	--set-string queues.test.runtime=sysbox \
	--set queues.test.ephemeralAgent=true \
	--set-string agentToken.value=unused)
image_for() { grep -A1 -- "- name: $1\$" <<<"${rendered}" | sed -n 's/^ *image: "\(.*\)"$/\1/p'; }
DIND_IMAGE=$(image_for dockerd)
CLI_IMAGE=$(image_for supervisor)
[[ -n "${DIND_IMAGE}" && -n "${CLI_IMAGE}" ]]
ID="bk-supervisor-test-$$"

cleanup() {
	docker rm --force "${ID}-supervisor" "${ID}-dockerd" >/dev/null 2>&1 || true
	docker volume rm "${ID}-run" "${ID}-workspace" "${ID}-docker-config" >/dev/null 2>&1 || true
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

DOCKER_CONFIG_DIR=/etc/buildkite-agent/docker
docker run --detach --privileged --name "${ID}-dockerd" \
	--volume "${ID}-run:/var/run" --volume "${ID}-workspace:/buildkite" \
	--volume "${ID}-docker-config:${DOCKER_CONFIG_DIR}" \
	"${DIND_IMAGE}" dockerd --host=unix:///var/run/docker.sock >/dev/null
wait_for "Docker daemon" inner info
docker exec "${ID}-dockerd" sh -c "echo '{\"auths\":{}}' >${DOCKER_CONFIG_DIR}/config.json"

# The stand-in agent checks the supervisor's arguments, records which agent
# ran the job, and exits once the test releases it. Like the real agent, it
# treats SIGTERM as a request to finish its in-flight job before exiting.
docker exec -i "${ID}-dockerd" sh -c 'mkdir -p /ctx && cat >/ctx/agent && chmod +x /ctx/agent' <<'EOF'
#!/bin/sh
[ "$*" = "start --disconnect-after-job" ] || { echo "unexpected arguments: $*" >&2; exit 64; }
[ "$DOCKER_CONFIG" = /etc/buildkite-agent/docker ] && [ -f "$DOCKER_CONFIG/config.json" ] ||
	{ echo "Docker client configuration missing" >&2; exit 65; }
# /buildkite is the daemon's, so jobs can bind-mount the binary from there.
[ "$BUILDKITE_AGENT_BINARY_PATH" = /buildkite/bin/buildkite-agent ] &&
	cmp -s /usr/local/bin/buildkite-agent "$BUILDKITE_AGENT_BINARY_PATH" && [ -x "$BUILDKITE_AGENT_BINARY_PATH" ] ||
	{ echo "Agent binary missing from the workspace" >&2; exit 66; }
touch "$DOCKER_CONFIG/seen-$BUILDKITE_AGENT_NAME"
mkdir -p /buildkite/builds
touch "/buildkite/builds/$BUILDKITE_AGENT_NAME"
draining=0
trap 'draining=1' TERM
until [ -e "/buildkite/release-$BUILDKITE_AGENT_NAME" ] || [ "$draining" -eq 1 ]; do sleep 0.2; done
if [ "$draining" -eq 1 ]; then
	touch /buildkite/drain-started
	sleep 3
	touch /buildkite/drain-finished
fi
EOF
docker exec -i "${ID}-dockerd" sh -c 'cat >/ctx/Dockerfile && docker build --quiet --tag test-agent:1 /ctx >/dev/null' <<'EOF'
FROM busybox:1.37
COPY agent /usr/local/bin/buildkite-agent
EOF

docker run --detach --read-only --name "${ID}-supervisor" \
	--volume "${ID}-run:/var/run" \
	--volume "${ID}-docker-config:${DOCKER_CONFIG_DIR}" \
	--volume "$(pwd)/${SCRIPT}:/opt/supervisor/supervisor.sh:ro" \
	--env "DOCKER_CONFIG=${DOCKER_CONFIG_DIR}" \
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
# Every agent shares the Pod's Docker client configuration, which persists.
docker exec "${ID}-dockerd" test -e "${DOCKER_CONFIG_DIR}/seen-${first}"
wait_for "second agent's Docker client configuration" docker exec "${ID}-dockerd" test -e "${DOCKER_CONFIG_DIR}/seen-${second}"

# Stopping the supervisor must let the in-flight job drain, not kill it at the
# stop timeout.
docker stop --time 30 "${ID}-supervisor" >/dev/null
[[ "$(docker inspect --format '{{.State.ExitCode}}' "${ID}-supervisor")" == 0 ]]
! agent_running
docker exec "${ID}-dockerd" test -e /buildkite/drain-started
docker exec "${ID}-dockerd" test -e /buildkite/drain-finished || {
	echo "Agent was stopped before its in-flight job finished draining" >&2
	exit 1
}
[[ "$(inner inspect --format '{{.State.ExitCode}}' buildkite-agent)" == 0 ]] || {
	echo "Agent did not exit cleanly after draining" >&2
	exit 1
}

echo "Supervisor ran fresh agents for each job, cleaned state between them, and drained on shutdown"
