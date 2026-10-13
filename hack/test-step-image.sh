#!/usr/bin/env bash
# Exercises the step-image bootstrap script against a real Docker daemon. As in
# a Docker runner Pod, the daemon and the real agent image share only
# /var/run, /buildkite and the Docker client configuration. Jobs check out a
# local repository and plugin, so no Buildkite token or API is needed.

set -euo pipefail

HELM="${HELM:-helm}"
CHART_DIR="${HELM_CHART_DIR:-charts/buildkite-operator}"
SCRIPT="${CHART_DIR}/files/step-image.sh"
STEP_IMAGE="busybox:1.37"

# Use the chart's own images, as rendered for a persistent dind runner.
rendered=$("${HELM}" template test "${CHART_DIR}" \
	--api-versions keda.sh/v1alpha1/ScaledObject \
	--api-versions keda.sh/v1alpha1/TriggerAuthentication \
	--set-string queues.test.queue=test \
	--set queues.test.maxReplicas=1 \
	--set-string queues.test.runtime=dind \
	--set-string agentToken.value=unused)
image_for() { grep -A1 -- "- name: $1\$" <<<"${rendered}" | sed -n 's/^ *image: "\(.*\)"$/\1/p'; }
DIND_IMAGE=$(image_for dockerd)
AGENT_IMAGE=$(image_for agent)
[[ -n "${DIND_IMAGE}" && -n "${AGENT_IMAGE}" ]]
SCRIPT_PATH=$(sed -n 's/^ *value: "\/bin\/sh \(.*\)"$/\1/p' <<<"${rendered}")
[[ "${SCRIPT_PATH}" == /*/step-image.sh ]]
ID="bk-step-image-test-$$"
DOCKER_CONFIG_DIR=/etc/buildkite-agent/docker

cleanup() {
	docker rm --force "${ID}-agent" "${ID}-dockerd" >/dev/null 2>&1 || true
	docker volume rm "${ID}-run" "${ID}-workspace" "${ID}-docker-config" >/dev/null 2>&1 || true
}
trap cleanup EXIT

inner() { docker exec "${ID}-dockerd" docker "$@"; }
in_agent() { docker exec "${ID}-agent" "$@"; }
fail() {
	echo "$1" >&2
	[[ -z "${2:-}" ]] || cat "$2" >&2
	exit 1
}

wait_for() {
	local description="$1"
	shift
	for _ in $(seq 1 60); do
		if "$@" >/dev/null 2>&1; then
			return 0
		fi
		sleep 0.5
	done
	fail "Timed out waiting for ${description}"
}

docker run --detach --privileged --name "${ID}-dockerd" \
	--volume "${ID}-run:/var/run" --volume "${ID}-workspace:/buildkite" \
	--volume "${ID}-docker-config:${DOCKER_CONFIG_DIR}" \
	"${DIND_IMAGE}" dockerd --host=unix:///var/run/docker.sock >/dev/null
wait_for "Docker daemon" inner info

# The agent container copies its binary into the workspace, as the chart's
# agents do, and holds the repository and plugin the jobs check out.
docker run --detach --name "${ID}-agent" --hostname runner-pod \
	--volume "${ID}-run:/var/run" --volume "${ID}-workspace:/buildkite" \
	--volume "${ID}-docker-config:${DOCKER_CONFIG_DIR}" \
	--volume "$(pwd)/${SCRIPT}:${SCRIPT_PATH}:ro" \
	--entrypoint /bin/sh "${AGENT_IMAGE}" \
	-c 'mkdir -p /buildkite/bin && cp /usr/local/bin/buildkite-agent /buildkite/bin/ && exec sleep infinity' >/dev/null
wait_for "agent binary copy" in_agent test -x /buildkite/bin/buildkite-agent
in_agent sh -ec '
	git config --global user.name test
	git config --global user.email test@example.com
	git init --quiet --initial-branch main /srv/repo
	echo checked-out >/srv/repo/checked-out.txt
	git -C /srv/repo add . && git -C /srv/repo commit --quiet -m repo
	# Records which container each hook ran in: only the agent image is Alpine.
	mkdir -p /srv/marker-buildkite-plugin/hooks
	for hook in post-checkout pre-command; do
		printf "#!/bin/sh\nif [ -e /etc/alpine-release ]; then where=agent; else where=image; fi\necho \$where >/buildkite/$hook-\$BUILDKITE_JOB_ID\n" \
			>/srv/marker-buildkite-plugin/hooks/$hook
		chmod +x /srv/marker-buildkite-plugin/hooks/$hook
	done
	# Cancelled jobs clean up slowly in the image, as within the grace period
	# they may.
	printf "#!/bin/sh\ncase \$BUILDKITE_JOB_ID in cancel-*) [ -e /etc/alpine-release ] || { sleep 2; touch /buildkite/pre-exit-\$BUILDKITE_JOB_ID; } ;; esac\n" \
		>/srv/marker-buildkite-plugin/hooks/pre-exit
	chmod +x /srv/marker-buildkite-plugin/hooks/pre-exit
	# With DELAY_DOCKER set to a docker subcommand, the CLI waits before running
	# it, ignoring SIGTERM as a CLI with a request in flight would.
	mkdir -p /usr/local/sbin
	printf "#!/bin/sh\nif [ \"\$1\" = \"\${DELAY_DOCKER:-}\" ]; then trap \"\" TERM; touch /tmp/delayed-\$BUILDKITE_JOB_ID; sleep 1; fi\nexec /usr/bin/docker \"\$@\"\n" \
		>/usr/local/sbin/docker
	chmod +x /usr/local/sbin/docker
	git -C /srv/marker-buildkite-plugin init --quiet --initial-branch main
	git -C /srv/marker-buildkite-plugin add . && git -C /srv/marker-buildkite-plugin commit --quiet -m plugin'

# The environment the agent gives a job, with the chart's paths. The step
# image has no bash, so commands use sh. Always cloning plugins fresh must not
# reach the step image, which has no git.
job_env=(
	--env PATH=/buildkite/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
	--env BUILDKITE_BIN_PATH=/usr/local/bin
	--env BUILDKITE_AGENT_NAME=runner-pod
	--env BUILDKITE_AGENT_ACCESS_TOKEN=unused
	--env BUILDKITE_AGENT_ENDPOINT=http://127.0.0.1:1
	--env BUILDKITE_ORGANIZATION_SLUG=org
	--env BUILDKITE_PIPELINE_SLUG=pipeline
	--env BUILDKITE_PIPELINE_PROVIDER=git
	--env BUILDKITE_BUILD_PATH=/buildkite/builds
	--env BUILDKITE_PLUGINS_PATH=/buildkite/plugins
	--env BUILDKITE_SOCKETS_PATH=/buildkite/sockets
	--env BUILDKITE_REPO=/srv/repo
	--env BUILDKITE_COMMIT=HEAD
	--env BUILDKITE_COMMIT_RESOLVED=true
	--env BUILDKITE_BRANCH=main
	--env 'BUILDKITE_PLUGINS=[{"/srv/marker-buildkite-plugin":null}]'
	--env BUILDKITE_PLUGINS_ALWAYS_CLONE_FRESH=true
	--env 'BUILDKITE_SHELL=/bin/sh -e -c'
	--env BUILDKITE_CANCEL_SIGNAL_TIMEOUT=10s
	--env DOCKER_HOST=unix:///var/run/docker.sock
	--env "DOCKER_CONFIG=${DOCKER_CONFIG_DIR}"
)
logs=$(mktemp -d)
trap 'cleanup; rm -rf "${logs}"' EXIT

# Starts a job in the background, in its own process group as the agent runs
# it, recording its PID and exit status in the agent container. A fourth
# argument sets an extra variable.
start_job() {
	local id="$1" image="$2" command="$3"
	docker exec --detach "${job_env[@]}" --env "BUILDKITE_JOB_ID=${id}" --env "BUILDKITE_IMAGE=${image}" \
		--env "${4:-DELAY_DOCKER=}" \
		--env "BUILDKITE_COMMAND=${command}" "${ID}-agent" bash -c \
		'set -m; /bin/sh "$1" >"/tmp/$2.log" 2>&1 & echo $! >"/tmp/$2.pid"; wait $!; echo $? >"/tmp/$2.status"' \
		bash "${SCRIPT_PATH}" "${id}"
	wait_for "job ${id} to start" in_agent test -s "/tmp/${id}.pid"
}
# Waits for a job and prints its exit status, keeping its log.
finish_job() {
	wait_for "job $1 to finish" in_agent test -s "/tmp/$1.status"
	in_agent cat "/tmp/$1.log" >"${logs}/$1.log"
	in_agent cat "/tmp/$1.status"
}
step_containers() { inner ps --all --quiet --filter "label=buildkite.com/job-id=$1"; }
step_container_running() { [[ -n "$(inner ps --quiet --filter "label=buildkite.com/job-id=$1")" ]]; }

# With an image, the checkout and its hooks run in the agent; plugins, hooks
# and the command run in the image, with the Job API, the agent binary and the
# job's multi-line environment.
start_job image "${STEP_IMAGE}" 'test ! -e /etc/alpine-release
test "$(cat checked-out.txt)" = checked-out
buildkite-agent --version
buildkite-agent env get BUILDKITE_JOB_ID >/buildkite/job-api-image
touch /buildkite/command-image'
status=$(finish_job image)
[[ "${status}" == 0 ]] || fail "Image job exited with status ${status}" "${logs}/image.log"
grep -q '^~~~ Running in busybox:1.37$' "${logs}/image.log" || fail "Image job did not run in its image" "${logs}/image.log"
grep -q 'already checked out' "${logs}/image.log" || fail "Image job cloned its plugin again" "${logs}/image.log"
grep -q '^buildkite-agent version ' "${logs}/image.log" || fail "buildkite-agent did not run in the image" "${logs}/image.log"
in_agent test -e /buildkite/command-image || fail "Image job's command did not finish" "${logs}/image.log"
[[ "$(in_agent cat /buildkite/job-api-image)" == image ]] ||
	fail "Job API was not reachable from the image" "${logs}/image.log"
[[ "$(in_agent cat /buildkite/post-checkout-image)" == agent ]] || fail "Checkout hooks did not run in the agent" "${logs}/image.log"
[[ "$(in_agent cat /buildkite/pre-command-image)" == image ]] || fail "Command hooks did not run in the image" "${logs}/image.log"
[[ -z "$(step_containers image)" ]] || fail "Image job left its container behind"

# Without an image, the whole job runs in the agent as before.
start_job plain "" 'test -e /etc/alpine-release
touch /buildkite/command-plain'
status=$(finish_job plain)
[[ "${status}" == 0 ]] || fail "Job without an image exited with status ${status}" "${logs}/plain.log"
in_agent test -e /buildkite/command-plain || fail "Job without an image did not run its command" "${logs}/plain.log"
[[ "$(in_agent cat /buildkite/pre-command-plain)" == agent ]] || fail "Job without an image ran hooks elsewhere" "${logs}/plain.log"
if grep -q '^~~~ Running in' "${logs}/plain.log"; then
	fail "Job without an image ran in a container" "${logs}/plain.log"
fi

# The command's exit status is the job's.
start_job failing "${STEP_IMAGE}" 'exit 3'
status=$(finish_job failing)
[[ "${status}" == 3 ]] || fail "Failing image job exited with status ${status}, not 3" "${logs}/failing.log"

# Cancelling stops the container well within the agent's grace period, after
# its cleanup hooks, both when only the script is signalled and when, as the
# agent does, its whole process group is.
for target in script group; do
	start_job "cancel-${target}" "${STEP_IMAGE}" 'sleep 600'
	wait_for "cancel-${target} container" step_container_running "cancel-${target}"
	pid=$(in_agent cat "/tmp/cancel-${target}.pid")
	if [[ "${target}" == group ]]; then
		pid="-${pid}"
	fi
	started=$(date +%s)
	in_agent kill -TERM "${pid}"
	status=$(finish_job "cancel-${target}")
	elapsed=$(($(date +%s) - started))
	[[ "${status}" != 0 ]] || fail "Cancelled job (${target}) exited with status 0" "${logs}/cancel-${target}.log"
	[[ "${elapsed}" -lt 9 ]] || fail "Cancelled job (${target}) took ${elapsed}s to stop" "${logs}/cancel-${target}.log"
	[[ -z "$(step_containers "cancel-${target}")" ]] || fail "Cancelled job (${target}) left its container running"
	in_agent test -e "/buildkite/pre-exit-cancel-${target}" ||
		fail "Cancelled job (${target}) was killed before its pre-exit hook finished" "${logs}/cancel-${target}.log"
done

# A job cancelled before docker run has started its container doesn't leave
# it running.
start_job cancel-starting "${STEP_IMAGE}" 'sleep 600' DELAY_DOCKER=run
wait_for "cancel-starting docker run" in_agent test -e /tmp/delayed-cancel-starting
in_agent kill -TERM "-$(in_agent cat /tmp/cancel-starting.pid)"
status=$(finish_job cancel-starting)
[[ "${status}" != 0 ]] || fail "Job cancelled while starting exited with status 0" "${logs}/cancel-starting.log"
[[ -z "$(step_containers cancel-starting)" ]] || fail "Job cancelled while starting left its container behind"

echo "Step images ran plugins, hooks and commands in the image after checking out in the agent, and stopped on cancellation"
