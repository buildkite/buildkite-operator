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
	--set-string defaults.docker.defaultStepImage=test-step:default \
	--set-string agentToken.value=unused)
image_for() { grep -A1 -- "- name: $1\$" <<<"${rendered}" | sed -n 's/^ *image: "\(.*\)"$/\1/p'; }
DIND_IMAGE=$(image_for dockerd)
CLI_IMAGE=$(image_for supervisor)
[[ -n "${DIND_IMAGE}" && -n "${CLI_IMAGE}" ]]
STEP_IMAGE_SCRIPT=$(grep -A1 -- '- name: STEP_IMAGE_SCRIPT$' <<<"${rendered}" | sed -n 's/^ *value: //p')
[[ "${STEP_IMAGE_SCRIPT}" == /opt/step-image/step-image.sh ]]
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
	--volume "$(pwd)/${CHART_DIR}/files/step-image.sh:${STEP_IMAGE_SCRIPT}:ro" \
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
source=/usr/local/bin/buildkite-agent
if [ "$(cat "$DOCKER_CONFIG/expected-runtime")" = ubuntu ]; then
	. /etc/os-release
	[ "$ID" = ubuntu ] || { echo "Agent did not run in Ubuntu" >&2; exit 69; }
	source=/opt/buildkite-agent-source/usr/local/bin/buildkite-agent
	if touch /opt/buildkite-agent-source/write-test 2>/dev/null; then
		echo "Source image mount is writable" >&2; exit 70
	fi
	[ ! -e /usr/local/bin/buildkite-agent ] || { echo "Source was merged over runtime root" >&2; exit 71; }
fi
[ "$(command -v buildkite-agent)" = /buildkite/bin/buildkite-agent ] &&
	cmp -s "$source" /buildkite/bin/buildkite-agent ||
	{ echo "Agent binary not first on PATH from the workspace" >&2; exit 66; }
# Jobs run through the step-image script, from the Docker daemon's container.
[ "$BUILDKITE_BOOTSTRAP_SCRIPT_PATH" = "/bin/sh /opt/step-image/step-image.sh" ] && [ -f /opt/step-image/step-image.sh ] &&
	[ "$BUILDKITE_JOB_CONTEXT_DIR" = /buildkite/job-context ] ||
	{ echo "Agent does not run jobs through the step-image script" >&2; exit 67; }
[ "$DEFAULT_STEP_IMAGE" = test-step:default ] ||
	{ echo "Agent did not inherit the default command image" >&2; exit 68; }
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

expected=busybox
if [[ -n "${TEST_AGENT_RUNTIME_IMAGE:-}" ]]; then
	expected=ubuntu
	# Keep image download time outside the agent-readiness deadline.
	inner pull --quiet "${TEST_AGENT_RUNTIME_IMAGE}" >/dev/null
fi
docker exec "${ID}-dockerd" sh -c 'printf "%s" "$1" >"$2/expected-runtime"' sh "${expected}" "${DOCKER_CONFIG_DIR}"
start_supervisor() {
	docker run --detach --read-only --name "${ID}-supervisor" \
		--volume "${ID}-run:/var/run" \
		--volume "${ID}-docker-config:${DOCKER_CONFIG_DIR}" \
		--volume "$(pwd)/${SCRIPT}:/opt/supervisor/supervisor.sh:ro" \
		--env "DOCKER_CONFIG=${DOCKER_CONFIG_DIR}" \
		--env "AGENT_IMAGE=$1" --env BUILDKITE_AGENT_TOKEN=unused \
		--env "AGENT_RUNTIME_IMAGE=${TEST_AGENT_RUNTIME_IMAGE:-}" \
		--env AGENT_TAGS=queue=test --env POD_NAME=runner-pod \
		--env TERMINATION_GRACE_PERIOD_SECONDS=20 \
		--env "STEP_IMAGE_SCRIPT=${STEP_IMAGE_SCRIPT}" \
		--env DEFAULT_STEP_IMAGE=test-step:default \
		"${CLI_IMAGE}" /bin/sh /opt/supervisor/supervisor.sh >/dev/null
}
start_supervisor test-agent:1

wait_for "first agent" agent_running
first=$(agent_name)
[[ "${first}" == runner-pod-???? ]]
wait_for "first agent's runtime checks" docker exec "${ID}-dockerd" test -e "${DOCKER_CONFIG_DIR}/seen-${first}"

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
if [[ -n "${TEST_AGENT_RUNTIME_IMAGE:-}" ]]; then
	# A source without the agent must fail closed, not start some binary from
	# the runtime or reuse a stale shared copy left by the previous agent.
	docker rm "${ID}-supervisor" >/dev/null
	inner tag busybox:1.37 test-agent:missing
	start_supervisor test-agent:missing
	startup_failed() { docker logs "${ID}-supervisor" 2>&1 | grep -q 'Agent exited with status 1'; }
	wait_for "missing source binary failure" startup_failed
	! agent_running
	docker exec "${ID}-dockerd" test ! -e /buildkite/bin/buildkite-agent
	docker stop --time 30 "${ID}-supervisor" >/dev/null
	echo "Missing source binary blocked agent startup without retaining the previous shared copy"
else
	cleanup
	trap - EXIT
	TEST_AGENT_RUNTIME_IMAGE=buildkite/agent-base:ubuntu-noble-hosted-toolchains "$0"
fi
