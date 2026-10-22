#!/bin/sh
# Runs each Buildkite job in a fresh agent container inside the Pod's Docker
# daemon. The agent exits after one job; the supervisor clears the job's state
# and starts a replacement. The Pod, its node, and the Docker image and build
# caches persist across jobs.
set -u

agent_container="buildkite-agent"
stopping=0
log_pid=""

log() { printf 'supervisor: %s\n' "$*"; }

stop_log_follower() {
	if [ -n "$log_pid" ]; then
		kill "$log_pid" >/dev/null 2>&1 || true
		wait "$log_pid" >/dev/null 2>&1 || true
		log_pid=""
	fi
}

shutdown() {
	trap - TERM INT
	stopping=1
	log "Stopping agent"
	stop_log_follower
	if docker info >/dev/null 2>&1; then
		# Leave time for the daemon to stop after the agent drains its job.
		timeout=$((TERMINATION_GRACE_PERIOD_SECONDS - 10))
		if [ "$timeout" -lt 0 ]; then
			timeout=0
		fi
		docker stop --time "$timeout" "$agent_container" >/dev/null 2>&1 || true
	fi
	exit 0
}

trap shutdown TERM INT

wait_for_docker() {
	while ! docker info >/dev/null 2>&1; do
		if [ "$stopping" -eq 1 ]; then
			return 1
		fi
		sleep 1
	done
}

agent_running() {
	[ "$(docker inspect --format '{{.State.Running}}' "$agent_container" 2>/dev/null)" = "true" ]
}

# A fresh name per agent avoids colliding with the previous agent while
# Buildkite finishes disconnecting it.
random_suffix() {
	LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 4
}

# Remove everything the previous job left in the daemon and workspace. The
# image and build caches are kept. A failure blocks the next agent so a job
# never starts on unclean state.
clean_job_state() {
	containers=$(docker ps --all --quiet) || return 1
	if [ -n "$containers" ]; then
		log "Removing $(printf '%s\n' "$containers" | wc -l | tr -d ' ') container(s)"
		# Docker's newline-separated IDs must be separate arguments.
		# shellcheck disable=SC2086
		docker rm --force --volumes $containers >/dev/null || return 1
	fi
	docker network prune --force >/dev/null || return 1
	docker volume prune --all --force >/dev/null || return 1
	# The supervisor cannot write the workspace, so clear the daemon's copy as
	# root in a throwaway container.
	docker run --rm --pull never --network none --user 0 --entrypoint /bin/sh \
		--volume /buildkite:/buildkite "$AGENT_IMAGE" \
		-c 'rm -rf /buildkite/* /buildkite/.[!.]* /buildkite/..?*' || return 1
	log "Cleaned job state"
}

start_agent() {
	if ! docker image inspect "$AGENT_IMAGE" >/dev/null 2>&1; then
		log "Pulling $AGENT_IMAGE"
		docker pull --quiet "$AGENT_IMAGE" >/dev/null || return 1
	fi

	clean_job_state || return 1

	# With step images, each agent runs jobs through the step-image script,
	# which the Docker daemon's container has at the same path.
	set --
	if [ -n "${STEP_IMAGE_SCRIPT:-}" ]; then
		set -- --volume "${STEP_IMAGE_SCRIPT%/*}:${STEP_IMAGE_SCRIPT%/*}:ro" \
			--env "BUILDKITE_BOOTSTRAP_SCRIPT_PATH=/bin/sh $STEP_IMAGE_SCRIPT" \
			--env BUILDKITE_JOB_CONTEXT_DIR=/buildkite/job-context \
			--env DEFAULT_STEP_IMAGE
	fi

	agent_name="${POD_NAME}-$(random_suffix)"
	log "Starting agent $agent_name"
	# DOCKER_CONFIG is at the same path in the Docker daemon's container, so
	# every agent shares the Pod's registry credentials and logins. The daemon
	# resolves bind-mount sources in that container, which shares only the
	# workspace with the agent, so jobs whose plugins mount the agent binary
	# (mount-buildkite-agent) find a copy there first on PATH.
	docker run --detach --pull never \
		--name "$agent_container" \
		--hostname "$POD_NAME" \
		--publish 8080:8080 \
		--volume /var/run/docker.sock:/var/run/docker.sock \
		--volume /buildkite:/buildkite \
		--volume "$DOCKER_CONFIG:$DOCKER_CONFIG" \
		--env DOCKER_CONFIG \
		--entrypoint /bin/sh \
		--env BUILDKITE_AGENT_CONFIG=/dev/null \
		--env BUILDKITE_AGENT_TOKEN \
		--env "BUILDKITE_AGENT_NAME=$agent_name" \
		--env "BUILDKITE_AGENT_TAGS=$AGENT_TAGS" \
		--env BUILDKITE_AGENT_HEALTH_CHECK_ADDR=0.0.0.0:8080 \
		--env BUILDKITE_BUILD_PATH=/buildkite/builds \
		--env BUILDKITE_PLUGINS_PATH=/buildkite/plugins \
		--env BUILDKITE_SOCKETS_PATH=/buildkite/sockets \
		--env DOCKER_HOST=unix:///var/run/docker.sock \
		"$@" \
		"$AGENT_IMAGE" -c 'mkdir -p /buildkite/bin &&
			cp /usr/local/bin/buildkite-agent /buildkite/bin/ &&
			export PATH="/buildkite/bin:$PATH" &&
			exec /usr/local/bin/buildkite-agent start --disconnect-after-job' >/dev/null
}

follow_agent_logs() {
	if [ "$1" = "adopted" ]; then
		docker logs --tail 0 --follow "$agent_container" &
	else
		docker logs --follow "$agent_container" &
	fi
	log_pid=$!
}

while [ "$stopping" -eq 0 ]; do
	wait_for_docker || break

	if agent_running; then
		log "Adopting running agent"
		follow_agent_logs adopted
	elif start_agent; then
		follow_agent_logs new
	else
		log "Could not start agent; retrying"
		sleep 5
		continue
	fi

	# Wait in the background so SIGTERM interrupts the shell's wait builtin.
	docker wait "$agent_container" >/dev/null 2>&1 &
	wait $! || true
	stop_log_follower

	if [ "$stopping" -eq 1 ]; then
		break
	fi
	status=$(docker inspect --format '{{.State.ExitCode}}' "$agent_container" 2>/dev/null || echo unknown)
	log "Agent exited with status $status"
	if [ "$status" != "0" ]; then
		# Avoid re-registering in a tight loop when the agent cannot start.
		sleep 5
	fi
done
