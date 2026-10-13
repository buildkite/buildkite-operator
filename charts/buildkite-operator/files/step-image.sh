#!/bin/sh
# The agent's bootstrap-script on dind, kata and sysbox runners: the command
# the agent runs for each job instead of `buildkite-agent bootstrap`.
#
# A step's image: sets BUILDKITE_IMAGE. Without it the job runs as usual. With
# it, as in agent-stack-k8s, plugins and the repository are checked out here in
# the agent, then plugins, hooks and the command run in a container from that
# image in the Pod's Docker daemon. The daemon shares /buildkite with the
# agent, so the container sees the checkout, plugins, Job API socket and the
# agent binary at the same paths.
set -uf

agent="$BUILDKITE_BIN_PATH/buildkite-agent"
if [ -z "${BUILDKITE_IMAGE:-}" ]; then
	exec "$agent" bootstrap
fi

container="buildkite-step-$BUILDKITE_JOB_ID"
created=0
cancelled=0

# The agent kills the job's processes BUILDKITE_CANCEL_SIGNAL_TIMEOUT after
# signalling them. A killed docker CLI would leave the container running, so
# give it a second less to stop.
grace=${BUILDKITE_CANCEL_SIGNAL_TIMEOUT:-10s}
grace=${grace%s}
case $grace in '' | *[!0-9]*) grace=10 ;; esac
stop_timeout=$((grace > 1 ? grace - 1 : 0))

# The agent signals the job's whole process group. The bootstrap stops
# handling signals after the first, so a second would kill it during its
# cleanup hooks, and each process must be signalled only once. The checkout
# bootstrap is in the group, so it gets the signal directly. docker start
# runs in its own session, so it gets no signal to forward, and this stops
# the container instead, which also works when only this script was
# signalled. A container that hasn't started yet is removed, so that a
# pending docker start fails; one that starts just then is killed outright.
cancel() {
	cancelled=1
	if [ "$created" -eq 1 ]; then
		if [ "$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null)" = created ]; then
			docker rm --force "$container" >/dev/null 2>&1 || true
		else
			docker stop --time "$stop_timeout" "$container" >/dev/null 2>&1 || true
		fi
	fi
}
trap cancel TERM INT HUP QUIT

# Runs a command in the background, so that signals interrupt the wait, and
# returns its exit status once it exits.
run() {
	"$@" &
	child=$!
	while :; do
		wait "$child"
		status=$?
		kill -0 "$child" 2>/dev/null || return "$status"
	done
}

# Exits unless the last step succeeded and the job hasn't been cancelled.
check() {
	[ "$1" -eq 0 ] || exit "$1"
	[ "$cancelled" -eq 0 ] || exit 1
}

run "$agent" bootstrap --phases plugin,checkout
check $?

# Pass the job's environment by name, so values with newlines survive, except
# for variables that describe the agent's container rather than the job. The
# plugins were just checked out, so don't clone them again: the image needs no
# git.
set --
names=$(awk 'BEGIN { for (name in ENVIRON) print name }')
IFS='
'
for name in $names; do
	case $name in
	PATH | HOME | HOSTNAME | PWD | OLDPWD | SHLVL | _ | BUILDKITE_BIN_PATH | BUILDKITE_PLUGINS_ALWAYS_CLONE_FRESH) ;;
	*) set -- "$@" --env "$name" ;;
	esac
done
unset IFS

# The container gets the agent binary's directory, which the bootstrap
# appends to PATH, and the same Docker daemon and client configuration as the
# agent. Its stop signal is the one the bootstrap handles, not the image's.
# Creating it pulls the image if needed.
printf '~~~ Running in %s\n' "$BUILDKITE_IMAGE"
run docker create --rm --init --stop-signal SIGTERM --name "$container" \
	--label "buildkite.com/job-id=$BUILDKITE_JOB_ID" \
	--volume /buildkite:/buildkite \
	--volume /var/run/docker.sock:/var/run/docker.sock \
	--volume "$DOCKER_CONFIG:$DOCKER_CONFIG" \
	"$@" \
	--env BUILDKITE_BIN_PATH=/buildkite/bin \
	--entrypoint /buildkite/bin/buildkite-agent \
	"$BUILDKITE_IMAGE" bootstrap --phases plugin,command >/dev/null
status=$?
created=1
if [ "$status" -ne 0 ] || [ "$cancelled" -eq 1 ]; then
	docker rm --force "$container" >/dev/null 2>&1
	exit $((status == 0 ? 1 : status))
fi
run setsid docker start --attach "$container"
