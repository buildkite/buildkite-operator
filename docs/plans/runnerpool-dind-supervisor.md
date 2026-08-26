# RunnerPool Docker-in-Docker Supervisor

## Problem

`RunnerPool` directly owns autoscaled Pods that run the Buildkite agent as
their only container. Replace that execution model universally with a private
Docker daemon and a supervisor in every runner Pod, without regressing the
idle-buffer autoscaling and graceful scale-down behavior.

Each directly owned Pod contains:

1. **PC1, `dockerd`**: a rootful, privileged, Kubernetes-native sidecar running
   a standalone Docker daemon.
2. **PC2, `supervisor`**: an unprivileged Docker CLI container running an
   operator-owned shell script.
3. **DC1, `buildkite-agent`**: the agent container launched by PC2 through PC1.

```text
RunnerPool-owned Pod
┌──────────────────────────────────────────────────────────┐
│ PC1: dockerd native sidecar                              │
│   privileged, rootful, Unix socket only                  │
│   /var/run/docker.sock ───────────────────┐              │
│   /var/lib/docker                         │              │
│   /workspace                              │              │
│                                           │              │
│ PC2: supervisor                           │              │
│   non-root shell + Docker CLI ◀───────────┘              │
│   keeps exactly one DC1 running                          │
│                 │                                        │
│                 ▼                                        │
│ DC1: Buildkite agent                                     │
│   health port 8080 published to the Pod                  │
│   /var/run/docker.sock                                   │
│   /workspace/builds and /workspace/plugins               │
│                 │                                        │
│                 ▼                                        │
│ job containers created by PC1 dockerd                    │
└──────────────────────────────────────────────────────────┘
```

PC1 and DC1 must see bind-mount source paths at the same absolute location.
Docker resolves sources in the daemon's filesystem, not in the client
container.

The implementation is based on `origin/prototype-dur` after the directly
managed Pod and idle-buffer autoscaling work. It must extend that architecture,
not restore the previous Deployment reconciler.

## API

The intended shape is:

```yaml
apiVersion: buildkite.com/v1alpha1
kind: RunnerPool
metadata:
  name: linux-builders
spec:
  queue: linux-amd64
  maxRunners: 20
  minIdleRunners: 3
  idleTimeoutSeconds: 30
  terminationGracePeriodSeconds: 3600
  agentImage: buildkite/agent:3
  agentTokenSecretRef:
    name: buildkite-agent-token
    key: token
  resources:
    requests:
      cpu: "2"
      memory: 4Gi
      ephemeral-storage: 20Gi
    limits:
      cpu: "4"
      memory: 8Gi
      ephemeral-storage: 50Gi
  docker:
    daemonImage: docker:29.7.2-dind
    supervisorImage: docker:29.7.2-cli
    configSecretRef:
      name: registry-credentials
  nodeSelector:
    buildkite.com/runner: "true"
  tolerations:
    - key: buildkite.com/runner
      operator: Equal
      value: "true"
      effect: NoSchedule
```

- Preserve `maxRunners`, `minIdleRunners`, `idleTimeoutSeconds`, and their
  autoscaling semantics.
- Rename `spec.image` to `spec.agentImage` without a deprecated alias.
- Keep the existing 3600-second termination grace period default.
- Add optional daemon and supervisor image overrides, defaulting to matching
  Docker 29.7.2 images.
- Add one optional `kubernetes.io/dockerconfigjson` Secret reference.
- Redefine `spec.resources` as PC1's resource envelope, accounting for dockerd,
  DC1, and nested jobs.
- Add node selector and toleration fields for dedicated privileged workers.
- Do not add arbitrary environment, command or argument overrides, persistent
  storage, affinity, or a general Pod template.

The daemon image must support the official dind entrypoint and explicit
`dockerd` invocation. The supervisor image must provide a POSIX `/bin/sh` and a
compatible Docker CLI.

## Pod contract

Continue creating directly owned Pods named `<pool>-agent-*`. The complete
desired Pod spec remains the input to the existing template hash, so changes
roll through confirmed-idle Pods. Existing direct-agent Pods have an old hash
and migrate through the same stale-Pod replacement path; busy agents are not
interrupted.

Pod-wide settings:

- Require Kubernetes 1.29 or newer for native sidecars.
- Disable service-account token mounting.
- Apply the configured termination grace period, node selector, and
  tolerations.
- Use filesystem and supplementary group 2375.
- Use separate Pod-local `emptyDir` volumes for Docker data, `/var/run`, and
  `/workspace`.
- Add the optional Docker config Secret to `imagePullSecrets`, mount its
  `config.json` at `/docker-config` in PC1 and PC2, and bind that same directory
  read-only into DC1.

All storage is intentionally Pod-local. Replacing a Pod discards Docker data,
named volumes, workspace contents, and caches.

### PC1: dockerd

- Run as a restartable init container (`restartPolicy: Always`) so it starts
  before PC2 and terminates after PC2.
- Run rootful and privileged with `spec.resources`.
- Mount Docker data, `/var/run`, `/workspace`, and optional registry config.
- Invoke `/usr/local/bin/dockerd-entrypoint.sh dockerd` with only the Unix
  socket and socket group 2375. Expose no Docker TCP listener.
- Use `docker info` startup and readiness probes. Do not use a liveness probe.

### PC2: supervisor

- Run the embedded POSIX shell supervisor using the configured CLI image.
- Run as fixed non-root UID 1000 and group 2375, drop all capabilities, and
  disallow privilege escalation.
- Use fixed requests of 10m CPU and 32Mi memory and limits of 100m CPU and
  128Mi memory.
- Mount the Docker socket and optional registry config.
- Receive the agent image, token Secret reference, queue tags, Pod name,
  shutdown budget, Docker host, and optional Docker config through environment
  variables.
- Declare port 8080 and use the published DC1 `/agent/1` endpoint for Pod
  readiness. Do not add a liveness probe.

## Supervisor lifecycle

1. Wait for `docker info`, including across PC1 restarts.
2. Adopt a running `buildkite-agent` after a PC2-only restart and follow only
   new logs.
3. Otherwise clean stale containers and networks, pull the agent image only
   when absent, and start one DC1.
4. Stream DC1 logs through PC2 and wait for any exit status. Run `docker wait`
   in the background and wait through the shell builtin so TERM traps remain
   interruptible.
5. After DC1 exits, force-remove all containers, prune unused custom networks,
   retain images, layers, BuildKit cache, volumes, and workspace, wait five
   seconds, then replace DC1.
6. On SIGTERM or SIGINT, prevent replacement, stop DC1 gracefully, reserve ten
   seconds for forced cleanup and PC1 shutdown, remove leftovers, and exit.

DC1 uses its image's normal entrypoint and user. It receives supplementary
group 2375, the agent token, queue tag, stable Pod-derived agent name, workspace
build/plugin paths, Docker socket, health server address, and optional Docker
config. It is not launched privileged, but socket access gives it
root-equivalent control of its private daemon. Port 8080 is published from DC1
to the Pod so kubelet readiness and the controller's `/status.json` polling
continue to drive autoscaling.

## Autoscaling and status

The existing controller remains responsible for observing Pods and polling the
published agent status endpoint:

- Busy agents add warm capacity up to `maxRunners`.
- Only confirmed-idle agents are scale-down candidates.
- Deletion is rechecked against `/status.json` immediately before eviction.
- Terminating Pods continue to occupy a hard-cap slot.
- Template changes replace idle stale Pods and leave busy stale Pods running.
- RunnerPool status continues reporting total, idle, busy, and ready runners.

An inner-agent restart temporarily makes its Pod unready and unavailable for
idle/busy classification, but does not replace the Kubernetes Pod or discard
its cache. The controller resumes polling after the replacement health endpoint
becomes ready.

## Bind-mount boundary

Guarantee daemon-visible sources only for:

- `/workspace/**`;
- `/var/run/docker.sock`;
- `/docker-config` when configured.

Normal Docker plugin checkout mounts work beneath `/workspace`. Arbitrary
DC1-only paths such as `/tmp`, image-local binaries, and SSH sockets cannot be
bind-mounted into child containers unless copied under a shared path. Do not
attempt to mirror DC1's root filesystem into PC1.

## Security

Rootful privileged DinD is not a hard Pod security boundary. Anyone controlling
DC1 or a job controls PC1's daemon, and PC1's privilege can potentially
compromise the Kubernetes node.

Mitigations are a private per-Pod daemon and socket, no node socket, no Docker
TCP listener, no Kubernetes service-account token, an unprivileged supervisor,
read-only registry credentials, resource controls, and dedicated-node
scheduling fields. Documentation must recommend dedicated tainted or
VM-isolated workers for untrusted builds.

## Verification

Controller and API tests cover:

- API defaults and renamed fields;
- PC1/PC2 topology, probes, security, resources, environment, and mounts;
- health publication and the interruptible supervisor wait;
- registry credentials and scheduling settings;
- template hash changes and migration of legacy direct-agent Pods;
- existing idle-buffer scaling, hard-cap, stale rollout, and status behavior.

Kind tests use public fixtures without a Buildkite API or token to prove:

- directly owned runner creation and inner-agent settings;
- nested Docker client/container execution;
- shared workspace bind mounts;
- Kubernetes Service DNS and connectivity;
- DC1 replacement, PC2 restart adoption, and cleanup;
- cache/workspace retention and graceful owner-reference deletion.

Run:

```sh
make manifests
make generate
make lint-fix
make test
make helm
make test-e2e
git status --short
```

Generated CRDs, DeepCopy code, RBAC, and Helm CRD templates must be regenerated,
not edited by hand.

## Non-goals

- Preserving direct Kubernetes agent-container execution.
- Backward compatibility for `spec.image`.
- Rootless DinD.
- Buildkite queue-depth integration.
- Persistent Docker or workspace storage across Pod replacement.
- Arbitrary agent environment, command, arguments, or Pod templates.
- Mirroring arbitrary DC1 filesystem paths into the daemon host.
- Restricting individual Docker API operations available to jobs.
- Running real Buildkite jobs in CI.
