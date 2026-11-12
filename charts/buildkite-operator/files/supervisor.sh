#!/bin/sh
# Runs each Buildkite job in a fresh agent container inside the Pod's Docker
# daemon. The agent exits after one job; the supervisor clears the job's state
# and starts a replacement. Image and build caches persist until Docker's data
# reaches the configured pruning threshold. Configured agent images are kept.
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

docker_usage_kib() {
	usage=$(docker run --rm --pull never --network none --user 0 --read-only --entrypoint /bin/sh \
		--volume /var/lib/docker:/docker-data:ro "$AGENT_IMAGE" \
		-c 'du -skx /docker-data') || return 1
	usage=${usage%%[[:space:]]*}
	case "$usage" in ''|*[!0-9]*) return 1 ;; esac
	printf '%s\n' "$usage"
}

# Remove job state every time, but keep image and build caches below the
# threshold. A cleanup failure blocks the next agent.
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
	# Clear the workspace and measure Docker data in the same root container.
	# A failed cleanup blocks startup; a failed measurement triggers pruning.
	# Stay on the data filesystem so du skips the helper's mounted rootfs.
	before=$(docker run --rm --pull never --network none --user 0 --entrypoint /bin/sh \
		--volume /buildkite:/buildkite --volume /var/lib/docker:/docker-data:ro "$AGENT_IMAGE" \
		-c 'rm -rf /buildkite/* /buildkite/.[!.]* /buildkite/..?* || exit 1
			if usage=$(du -skx /docker-data); then
				printf "%s\n" "${usage%%[[:space:]]*}"
			else
				echo unknown
			fi') || return 1
	log "Cleaned job state"
	case "$before" in
	''|*[!0-9]*)
		before=unknown
		log "Could not measure Docker data usage; pruning caches"
		;;
	*)
		log "Docker data uses ${before}KiB; prune threshold is ${DOCKER_PRUNE_THRESHOLD_KIB}KiB"
		if [ "$before" -lt "$DOCKER_PRUNE_THRESHOLD_KIB" ]; then
			return 0
		fi
		;;
	esac
	started=$(date +%s)
	# Stopped containers protect both configured images from pruning, including
	# the binary source when the agent runs in a separate runtime image. If
	# cleanup fails, the next attempt removes these with the other containers.
	keepers=""
	for image in "$AGENT_IMAGE" "${AGENT_RUNTIME_IMAGE:-}"; do
		[ -n "$image" ] || continue
		keeper=$(docker create --pull never --entrypoint /bin/sh "$image") || return 1
		keepers="$keepers $keeper"
	done
	docker image prune --all --force >/dev/null || return 1
	docker builder prune --all --force >/dev/null || return 1
	# shellcheck disable=SC2086
	docker rm --volumes $keepers >/dev/null || return 1
	if after=$(docker_usage_kib); then
		log "Pruned caches in $(($(date +%s) - started))s: ${before}KiB -> ${after}KiB"
		if [ "$after" -ge "$DOCKER_PRUNE_THRESHOLD_KIB" ]; then
			log "Warning: Docker data remains at or above the prune threshold; starting agent anyway"
		fi
	else
		log "Pruned caches in $(($(date +%s) - started))s; could not measure remaining Docker data usage"
	fi
}

start_agent() {
	for image in "$AGENT_IMAGE" "${AGENT_RUNTIME_IMAGE:-}"; do
		[ -n "$image" ] || continue
		if ! docker image inspect "$image" >/dev/null 2>&1; then
			log "Pulling $image"
			docker pull --quiet "$image" >/dev/null || return 1
		fi
	done

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

	if [ -n "${RUNNER_CPU_LIMIT_MILLICORES:-}" ]; then
		set -- "$@" --cpu-period 100000 \
			--cpu-quota "$((RUNNER_CPU_LIMIT_MILLICORES < 10 ? 1000 : RUNNER_CPU_LIMIT_MILLICORES * 100))" \
			--env RUNNER_CPU_LIMIT_MILLICORES
	fi

	image="$AGENT_IMAGE"
	agent_binary=/usr/local/bin/buildkite-agent
	agent_command="$agent_binary"
	if [ -n "${AGENT_RUNTIME_IMAGE:-}" ]; then
		case "$(docker info --format '{{json .DriverStatus}}')" in
		*io.containerd.snapshotter.v1*) ;;
		*) log "agentRuntimeImage requires Docker's containerd image store"; return 1 ;;
		esac
		image="$AGENT_RUNTIME_IMAGE"
		agent_binary=/opt/buildkite-agent-source/usr/local/bin/buildkite-agent
		# Run the shared copy so the agent's BUILDKITE_BIN_PATH is also visible
		# to sibling containers: they do not inherit the source image mount.
		agent_command=/buildkite/bin/buildkite-agent
		set -- "$@" --mount "type=image,source=$AGENT_IMAGE,target=/opt/buildkite-agent-source,readonly"
	fi

	agent_name="${POD_NAME}-$(random_suffix)"
	log "Starting agent $agent_name"
	# DOCKER_CONFIG is at the same path in the Docker daemon's container, so
	# every agent shares the Pod's registry credentials and logins. The daemon
	# resolves bind-mount sources in that container, which shares only the
	# workspace with the agent, so jobs whose plugins mount the agent binary
	# (mount-buildkite-agent) find a copy there first on PATH.
	docker run --detach --pull never \
		--stop-signal SIGTERM \
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
		"$image" -c 'mkdir -p /buildkite/bin &&
			cp "$1" /buildkite/bin/buildkite-agent &&
			export PATH="/buildkite/bin:$PATH" &&
			exec "$2" start --disconnect-after-job' agent "$agent_binary" "$agent_command" >/dev/null
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
