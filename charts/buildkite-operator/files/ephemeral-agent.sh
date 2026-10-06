#!/bin/sh
# Runs ephemeral agents for the standard runtime: each agent disconnects after
# one job, then this loop clears the workspace and starts a newly registered
# agent. The container itself keeps running, so the kubelet's restart backoff
# never applies. Only the build and plugin directories are reset; the rest of
# the container's filesystem persists across jobs.
set -u

base_name="${BUILDKITE_AGENT_NAME:?}"
build_path="${BUILDKITE_BUILD_PATH:?}"
plugins_path="${BUILDKITE_PLUGINS_PATH:?}"
stopping=0
agent_pid=""

log() { printf 'ephemeral-agent: %s\n' "$*"; }

# The kubelet signals only PID 1. The agent finishes its current job on the
# first SIGTERM but cancels it on a second, so forward exactly one.
shutdown() {
	if [ "$stopping" -eq 0 ] && [ -n "$agent_pid" ]; then
		log "Stopping agent"
		kill -TERM "$agent_pid" 2>/dev/null || true
	fi
	stopping=1
}
trap shutdown TERM INT

# Waits in the background so a signal interrupts the shell's wait builtin.
pause() {
	sleep "$1" &
	wait $! || true
}

# A fresh name per agent avoids colliding with the previous agent while
# Buildkite finishes disconnecting it.
random_suffix() {
	LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 4
}

clean_workspace() {
	for dir in "$build_path" "$plugins_path"; do
		rm -rf "${dir:?}"/* "$dir"/.[!.]* "$dir"/..?* || return 1
	done
}

while [ "$stopping" -eq 0 ]; do
	# A failure blocks the next agent so a job never starts on unclean state.
	if ! clean_workspace; then
		log "Could not clean workspace; retrying"
		pause 5
		continue
	fi

	agent_name="${base_name}-$(random_suffix)"
	log "Starting agent $agent_name"
	BUILDKITE_AGENT_NAME="$agent_name" /usr/local/bin/buildkite-agent start --disconnect-after-job &
	agent_pid=$!
	# A signal that arrived before agent_pid was set was not forwarded. The new
	# agent cannot have a job yet, so a second SIGTERM here would be harmless.
	if [ "$stopping" -eq 1 ]; then
		kill -TERM "$agent_pid" 2>/dev/null || true
	fi

	# wait returns early when a signal arrives; keep waiting for the agent.
	while :; do
		wait "$agent_pid"
		status=$?
		if [ "$status" -gt 128 ] && kill -0 "$agent_pid" 2>/dev/null; then
			continue
		fi
		break
	done
	agent_pid=""

	if [ "$stopping" -eq 1 ]; then
		break
	fi
	log "Agent exited with status $status"
	if [ "$status" -ne 0 ]; then
		# Avoid re-registering in a tight loop when the agent cannot start.
		pause 5
	fi
done
log "Stopped"
