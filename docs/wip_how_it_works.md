# How it works

## Step images

On `dind`, `kata` and `sysbox` runners, the agent runs each job through a
script from the chart instead of `buildkite-agent bootstrap`. When the job has
a step image or a default step image, the script starts a step container in
the Pod's Docker daemon. See [Step images](../README.md#step-images).

The step container:

- Runs one full `buildkite-agent bootstrap`: plugins, checkout, hooks and
  commands.
- Mounts the `/buildkite` workspace at the same path, so it sees the checkout,
  plugins, Job API socket and agent binary.
- Gets the job's environment, the Pod's Docker daemon and the Docker client
  configuration (`DOCKER_CONFIG`), like the agent.
- Carries environment and working-directory changes from hooks through to the
  command phase.
- Is named `buildkite-step-<job ID>` and labeled `buildkite.com/job-id`, is
  stopped when the job is cancelled and removed when the job finishes.

Agent 4.8 can still bring back a variable a hook unset, if it was set when the
bootstrap started, because its subprocess layer merges the original
environment back in. Variables that an earlier hook created and a later one
unset aren't affected.

## Agent runtime image

With `docker.agentRuntimeImage` set, the supervisor starts each agent in the
runtime image and mounts the agent `image` into it with a Docker `type=image`
mount. See [Agent runtime image](../README.md#agent-runtime-image).

- Docker mounts the agent image's filesystem read-only at
  `/opt/buildkite-agent-source`, rather than overlaying it on the runtime
  image's root.
- At startup, only the agent binary is copied to
  `/buildkite/bin/buildkite-agent`, and the agent runs that copy.
- That path is first on `PATH` and is the agent's `BUILDKITE_BIN_PATH`, so
  Docker and Docker Compose plugins and step containers can bind-mount it
  without the source image's mount.
- No extraction container or combined image is needed, and the workspace
  cleanup between jobs is unchanged.
- The supervisor refuses to start on a daemon without the containerd image
  store, rather than falling back to another way of getting the binary.

## OCI accelerator peering

With `ociAccelerator.peering.enabled`, the chart configures each proxy's peer
discovery. See [Peering](../README.md#peering).

- Each proxy is seeded with every replica's DNS name from the StatefulSet's
  headless Service, including its own, which the accelerator ignores.
- Seeds are DNS names, not Pod IPs, so replaced Pods can find each other again.
- Pods start in parallel, and peer DNS records are published before the Pods
  are ready.
- No Kubernetes API access or discovery sidecar is needed.
- Discovery and cache listings refresh asynchronously, so a new proxy can fetch
  from origin before it learns what its peers have.
