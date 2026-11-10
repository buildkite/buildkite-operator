# buildkite-operator

This repository contains a standalone Helm chart for running a Buildkite
runner stack on Kubernetes. One chart release can serve several Buildkite
queues. Each gets its own runner pool (a `Deployment` of runner Pods) and KEDA
scaling, and they share one token Secret.

The stack includes:

- Runner pools that KEDA [scales](#autoscaling) on each queue's job count.
- A choice of [isolation runtimes](#runtimes) for each pool.
- An optional [image pull cache](#image-pull-caching) shared by the runners.

## Prerequisites

Install the supported KEDA 2.20.0 release once in the cluster before installing
this chart:

```bash
helm upgrade --install keda keda \
  --repo https://kedacore.github.io/charts \
  --version 2.20.0 \
  --namespace keda \
  --create-namespace \
  --wait
```

After installing KEDA:

- If you've limited the namespaces KEDA watches (`watchNamespace`), include the
  one where you install this chart.
- With any runner pools configured, the chart fails to install unless KEDA's
  `ScaledObject` and `TriggerAuthentication` APIs are available.
- This check can't tell whether KEDA is healthy, watches the release namespace
  or is a supported version.
- To skip the check, set `keda.validateInstallation: false`.

Some features need more: Kubernetes 1.30 or later for the
[deletion-cost admission policy](docs/wip_deployment.md#deletion-cost-admission-policy),
native sidecars for the
[`dind`, `kata` and `sysbox` runtimes](#runtimes), and Kata or Sysbox
[installed on the nodes](docs/wip_deployment.md#installing-kata-and-sysbox) for
those runtimes.

## Quickstart

Add a runner pool under `runnerPools` for each Buildkite queue, with its maximum
runner count, and provide the cluster agent token. The pool name (`linux` below)
is used in resource names:

```bash
export BUILDKITE_AGENT_TOKEN='<agent-token>'

helm upgrade --install buildkite-operator ./charts/buildkite-operator \
  --namespace buildkite-runner-stack \
  --create-namespace \
  --set-string runnerPools.linux.queue=<queue> \
  --set runnerPools.linux.maxReplicas=<maximum> \
  --set-string agentToken.value="$BUILDKITE_AGENT_TOKEN"
```

Helm stores supplied values in its release data. For production, create the
token Secrets yourself. See
[Production secret management](docs/wip_deployment.md#production-secret-management).

## Runner pools

Each runner pool serves one Buildkite queue and inherits every setting from
`defaults`, overriding any of them. For example, a values file serving a Kata
pool and a Sysbox pool with ephemeral agents:

```yaml
defaults:
  minReplicas: 1

runnerPools:
  linux-kata:
    queue: linux
    runtime: kata
    maxReplicas: 10

  build-sysbox:
    queue: build
    runtime: sysbox
    ephemeralAgent: true
    minReplicas: 0
    maxReplicas: 4
    docker:
      resources:
        limits:
          memory: 16Gi
```

Pool rules:

- Every pool needs `queue` and `maxReplicas`.
- Pool names use lowercase letters, digits and hyphens, and start and end with
  a letter or digit.
- The release and pool names combined can be at most 50 characters.
- Each Buildkite queue can appear in only one pool, because KEDA scales a pool
  on its queue's whole job count.
- With no pools, the chart installs nothing.

Because `runnerPools` is a map, a later values file can change one pool
(`linux-kata: {maxReplicas: 25}`) or remove it (`build-sysbox: null`) without
restating the others.

Each pool gets a `Deployment` and a `ScaledObject`, both named
`<release>-<pool>`. Its Pods are labeled `buildkite.com/runner-pool: <pool>`.
All pools in a release share the token Secret, the KEDA
`TriggerAuthentication`, and the deletion-cost permissions and scripts. Queues
in a different Buildkite cluster need a different token, so put them in a
separate release.

| Setting | Description |
| --- | --- |
| `queue` | (required) Buildkite queue key the agents serve and scale on. |
| `maxReplicas` | (required) Upper bound on runners. |
| `minReplicas` | (default `1`) Runners kept when the queue is idle. |
| `runtime` | (default `standard`) `standard`, `dind`, `kata` or `sysbox`. See [Runtimes](#runtimes). |
| `ephemeralAgent` | (default `false`) Replace the agent after every job, with a clean workspace. The Pod persists. See [Ephemeral agents](#ephemeral-agents). |
| `terminationGracePeriodSeconds` | (default `3600`) Longest time an agent may take to drain its job. |
| `pollingInterval` | (default `10`) Seconds between KEDA's checks of the queue. |
| `cooldownPeriod` | (default `60`) Seconds the queue must be fully idle before KEDA scales a pool with `minReplicas: 0` to zero. See [Autoscaling](#autoscaling). |
| `scaleDownStabilizationWindowSeconds` | (default `60`) Seconds the HPA waits before removing runners after the job count drops (0–3600), while at least one runner is still needed. |
| `image` | (default `buildkite/agent:4`) Agent image. With `standard` and `ephemeralAgent`, it also needs `/bin/sh`. |
| `resources` | (default none) Kubernetes `requests` and `limits` for the agent container. With `dind`, `kata` or `sysbox` and `ephemeralAgent`, agents run inside the Docker daemon, so use [`docker.resources`](#docker-settings) instead. |
| `docker` | Docker daemon settings for `dind`, `kata` and `sysbox`. See [Docker settings](#docker-settings). |

### Docker settings

`dind`, `kata` and `sysbox` runners also take Docker daemon settings under
`docker`:

| Setting | Description |
| --- | --- |
| `docker.image` | (default `docker:29.7.2-dind`) Docker daemon image. |
| `docker.resources` | (default 2 CPUs, 4Gi memory and 15Gi disk requested, limited to 4 CPUs, 8Gi and 50Gi) Kubernetes `requests` and `limits` for the Docker daemon. With `ephemeralAgent`, they also bound the agent containers. |
| `docker.storage.data` | (default `40Gi`) Size limit of the `emptyDir` for Docker's data in `/var/lib/docker`. |
| `docker.storage.workspace` | (default `10Gi`) Size limit of the `emptyDir` for the `/buildkite` workspace. |
| `docker.ociAccelerator` | (default `true`) Pull through the [OCI accelerator](#image-pull-caching) when it is enabled. |
| `docker.stepImages` | (default `true`) Run steps that set `image:` in that image. See [Step images](#step-images). |
| `docker.defaultStepImage` | (default none) Image for steps without `image:`. See [Step images](#step-images). |
| `docker.agentRuntimeImage` | (default none) Separate runtime image for ephemeral agents. See [Agent runtime image](#agent-runtime-image). |

### Examples

#### Ephemeral standard agents

```yaml
runnerPools:
  linux:
    queue: linux
    ephemeralAgent: true
    maxReplicas: 10
```

- Each Pod runs a fresh agent for every job, with no Docker daemon.
- Between jobs: the workspace is emptied, but files outside it carry over
  because the container keeps running.
- Use it for jobs that don't need Docker.

#### Persistent Sysbox agents

```yaml
runnerPools:
  docker-builds:
    queue: docker-builds
    runtime: sysbox
    minReplicas: 0
    maxReplicas: 4
```

- Each Pod runs one long-lived agent next to an unprivileged Docker daemon.
- Between jobs: containers, volumes, checkouts and caches carry over.
- The pool scales to zero when the queue is idle.

#### Persistent Docker-in-Docker agents

```yaml
runnerPools:
  docker:
    queue: docker
    runtime: dind
    maxReplicas: 4
```

- Each Pod runs one long-lived agent next to a privileged Docker daemon, on any
  node.
- Between jobs: containers, volumes, checkouts and caches carry over.
- Use it only for trusted jobs on clusters that can't run Kata or Sysbox, and
  read [Privileged Docker-in-Docker](#privileged-docker-in-docker) first.

#### Ephemeral Kata agents

```yaml
runnerPools:
  untrusted:
    queue: untrusted
    runtime: kata
    ephemeralAgent: true
    maxReplicas: 6
```

- Each Pod runs a fresh agent container for every job, in a Docker daemon
  inside a VM.
- Between jobs: containers, networks, volumes and the workspace are removed,
  but Docker's image and build caches carry over.
- Use it for untrusted jobs, since each Pod runs in its own VM.

#### Turning a pool off

```yaml
# off.yaml
runnerPools:
  untrusted: null
```

- Apply it in a later values file, for example
  `helm upgrade ... -f values.yaml -f off.yaml`, or comment out or delete the
  pool instead.
- Helm removes the pool's `Deployment` and `ScaledObject`, and its agents drain
  their current jobs.
- To keep a pool without idle runners, set `minReplicas: 0` instead, since
  `maxReplicas` must be at least 1.

## Autoscaling

KEDA polls Buildkite's Agent Metrics API and sizes each runner pool to its
queue's `scheduled + running` job count, between `minReplicas` (one by default)
and `maxReplicas`.

Scaling in happens in one of two ways:

- While jobs are scheduled or running, the HPA removes runners only after the
  lower count has lasted `scaleDownStabilizationWindowSeconds`.
- Once the queue has no scheduled or running jobs, a pool with `minReplicas: 0`
  scales to zero after `cooldownPeriod`, removing every remaining runner at
  once.

When a runner is removed:

- Runner Pods with idle agents are removed first where possible. See
  [Scale-in preference](#scale-in-preference).
- The agent finishes its running job on its first SIGTERM, for up to
  `terminationGracePeriodSeconds`.
- Terminating Pods can briefly run alongside their replacements, so a pool can
  have more than `maxReplicas` Pods for a short time.

KEDA stays installed when you uninstall a release of this chart, and several
releases in the cluster can share it.

### Scale-in preference

Each runner Pod includes a small sidecar that polls the agent's
local `/status.json` endpoint every second. On each change between busy and
idle it patches two annotations together, retrying until the patch succeeds:

| Agent | Annotations |
| --- | --- |
| Busy or unknown (including at startup) | `controller.kubernetes.io/pod-deletion-cost: "100"`<br>`cluster-autoscaler.kubernetes.io/safe-to-evict: "false"` |
| Idle | `controller.kubernetes.io/pod-deletion-cost` removed<br>`cluster-autoscaler.kubernetes.io/safe-to-evict: "true"` |

The deletion cost makes the ReplicaSet prefer removing runner Pods with idle
agents. This is best-effort:

- Kubernetes can still remove a runner Pod whose agent is busy.
- Deletion cost doesn't protect against node drains or evictions.

The sidecar is always enabled, its Python image is pinned by digest, and it
holds the only Kubernetes API token in the Pod. The chart limits what that
token can change with an admission policy. See
[Deletion-cost admission policy](docs/wip_deployment.md#deletion-cost-admission-policy).

### Node autoscaling

This applies if your cluster runs
[Cluster Autoscaler](https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler),
which this chart doesn't install. Cluster Autoscaler removes underused nodes by
evicting their Pods, and caps graceful termination at
`--max-graceful-termination-sec` (600 seconds by default). That's well below
the chart's default `terminationGracePeriodSeconds`, so the `safe-to-evict`
annotation from [Scale-in preference](#scale-in-preference) steers it:

- A busy runner Pod's `"false"` stops Cluster Autoscaler from removing its
  node, so running jobs aren't cut short.
- An idle runner Pod's `"true"` lets Cluster Autoscaler remove its node, which
  its default `--skip-nodes-with-local-storage=true` would otherwise block for
  `dind`, `kata` and `sysbox` runners with their disk-backed `emptyDir`
  volumes.

This is best-effort:

- An agent that accepts a job after Cluster Autoscaler checks its node, but
  before eviction, is still cut off after `--max-graceful-termination-sec`.
- Node drains outside Cluster Autoscaler, such as `kubectl drain` or spot
  interruptions, ignore the annotation.

## Runtimes

Set `runtime` in `defaults` or on a runner pool to choose its runtime.
Different pools in one release can use different runtimes.

| Value | Runner Pod | Needs |
| --- | --- | --- |
| `standard` (default) | A Buildkite agent in a regular Kubernetes Pod, with no Docker daemon. | Nothing extra. |
| `dind` | An agent and privileged Docker native sidecar in a regular Pod on any node. Not isolation. See [Privileged Docker-in-Docker](#privileged-docker-in-docker). | Native sidecars, and a namespace that allows privileged Pods. |
| `kata` | An agent and privileged Docker native sidecar inside the `kata-qemu-runtime-rs` VM RuntimeClass. | Native sidecars, Kata on the nodes, and a namespace that allows privileged Pods. |
| `sysbox` | An agent and unprivileged Docker native sidecar using the `sysbox-runc` RuntimeClass and Kubernetes user namespaces. | Native sidecars, user namespaces, and Sysbox on the nodes. |

Kata and Sysbox are host runtimes that the chart doesn't install. See
[Installing Kata and Sysbox](docs/wip_deployment.md#installing-kata-and-sysbox).

### Privileged Docker-in-Docker

`runtime: dind` is for clusters that can't run Kata or Sysbox but whose jobs
need Docker. The Pod runs the same Docker daemon sidecar as `kata` and
`sysbox`, privileged and without a RuntimeClass, so it schedules on any node.

> [!WARNING]
> `dind` is not isolation. A privileged container can reach host devices, load
> kernel modules and escape to its node. Run only trusted jobs on `dind` pools,
> and keep their nodes apart from workloads those jobs must not reach.

The namespace must allow privileged Pods. `kata` runners need this too, because
their Docker daemon is privileged inside the VM. With Pod Security Admission:

```bash
# Allow privileged Pods in the release namespace
kubectl label namespace <namespace> pod-security.kubernetes.io/enforce=privileged
```

The chart adds no node selector or toleration for `dind`, so its Pods can land
on any node. Dedicated `dind` nodes aren't configurable yet.

### Bind mounts

The Docker daemon resolves bind-mount sources in its own container, which
shares only the `/buildkite` workspace with the agent:

- Jobs can bind-mount checkouts and other paths under `/buildkite` into their
  containers.
- Jobs can't bind-mount files from elsewhere in the agent's container.

So that the Docker and Docker Compose plugins' `mount-buildkite-agent` option
works, each agent copies its binary to `/buildkite/bin/buildkite-agent` and
puts that directory first on `PATH`, where the plugins look for it. The agent
image therefore needs `/bin/sh`.

## Ephemeral agents

`ephemeralAgent` controls the Buildkite agent, not the Pod:

- Runner Pods always persist across jobs, and only autoscaling adds or removes
  them.
- With `dind`, `kata` and `sysbox`, Docker data and the workspace live in the
  Pod and are discarded when it's removed.

By default (`ephemeralAgent: false`), one agent registers when its Pod starts
and runs job after job, so whatever a job leaves behind is there for the next.

With `ephemeralAgent: true`, the agent disconnects after each job, and a newly
registered agent named `<pod>-<suffix>` replaces it with a clean workspace:

- `standard`: a small loop in the agent container empties the build and plugin
  directories, then runs `buildkite-agent start --disconnect-after-job` again.
  The container never restarts, so restart backoff doesn't delay the next job.
  The agent image needs `/bin/sh`.
- `dind`, `kata`, `sysbox`: a supervisor starts each agent as a fresh container
  in the Pod's Docker daemon. After each job it removes the job's containers,
  networks and volumes, and clears the `/buildkite` workspace.

Ephemeral agents also behave as follows:

- If cleanup fails, no new agent starts until it succeeds.
- On SIGTERM, from scale-in, upgrades or node scale-down, the current agent
  finishes its job within `terminationGracePeriodSeconds`, and no further agent
  starts.
- While one agent replaces the next, the deletion-cost sidecar marks the Pod
  busy until the new agent reports idle, so scale-in prefers other Pods.

### What's reset between jobs

#### `standard`

<table>
<tr>
<th>Reset</th>
<td>The agent process and its registration, and the contents of
<code>/buildkite/builds</code> (checkouts) and
<code>/buildkite/plugins</code>.</td>
</tr>
<tr>
<th>Persist</th>
<td>The Pod, its node and the agent container, with the rest of its filesystem:
<code>/tmp</code>, the home directory, packages or tools a job installed, caches
outside <code>/buildkite</code>, and any processes a job left running.</td>
</tr>
</table>

#### `dind`, `kata` and `sysbox`

<table>
<tr>
<th>Reset</th>
<td>The agent container, recreated from the image, every Docker container,
network and volume, and the <code>/buildkite</code> workspace (checkouts,
plugins and sockets).</td>
</tr>
<tr>
<th>Persist</th>
<td>The Pod, its node and the Docker daemon, with Docker's image and build
caches and the Docker client configuration (<code>DOCKER_CONFIG</code>,
including logins).</td>
</tr>
</table>

### Security

Ephemeral agents keep jobs' state apart, but they aren't a security boundary.
Anything that persists, such as files outside the workspace in a `standard`
container or the Pod's Docker image cache, stays available to later jobs.

## Job images

### Step images

On `dind`, `kata` and `sysbox` runners, a command step's `image:` runs the
whole job in that image, including plugin and repository checkout. `standard`
runners have no Docker daemon, so they ignore `image:` and run the step in the
agent container.

Set a default whole-job image for steps without a nonempty `image:`:

```yaml
defaults:
  docker:
    defaultStepImage: buildkite/agent-base:ubuntu-noble-hosted-toolchains
```

Which image a step runs in:

- A nonempty step `image:` takes precedence over the default.
- Override `docker.defaultStepImage` per pool, or set it to `""` there to clear
  it.
- With neither, the usual bootstrap runs in the agent, unchanged.
- To ignore both and run every step in the agent, set
  `docker.stepImages: false` on a pool.
- `standard` runners ignore both, because they have no Docker daemon.
- `defaults.image` is unaffected and still supplies the agent binary.

For how the step container runs the job, see
[Step images](docs/wip_how_it_works.md#step-images) in How it works.

Images are pulled only when the Pod's daemon doesn't have them, so a cached
tag isn't updated until the Pod is replaced, even across ephemeral agents.
Private step images must be pullable with the existing Docker client
configuration, because a login in a job hook happens too late.

The step's image must:

- Match the agent binary's architecture.
- Include Git, `bash` (the default command shell), and any checkout, SSH/CA or
  plugin tools the job needs.
- Run as a user that can write to the shared workspace and, when needed, use
  the Docker socket.

It doesn't need the agent installed, because it runs the shared binary.

A pipeline-level `image:` applies to every step, including those using the
Docker or Docker Compose plugins, whose hooks then need the Docker CLI (and
Compose) in that image. Set `image:` only on the steps that need it, or use an
image with the Docker CLI.

### Agent runtime image

Ephemeral `dind`, `kata` and `sysbox` agents can run in a separate runtime
image, including their environment, plugin and checkout hooks:

```yaml
defaults:
  ephemeralAgent: true
  runtime: dind
  docker:
    agentRuntimeImage: buildkite/agent-base:ubuntu-noble-hosted-toolchains
```

- `image` still supplies the agent binary, and the runtime image provides
  everything else the agent runs with.
- Override `docker.agentRuntimeImage` per pool, or set it to `""` to clear an
  inherited runtime image.
- The chart rejects it for persistent agents and `standard` runners, rather
  than ignoring it.

Where the job runs:

- Without a step image, the whole job, including its first hooks, runs in the
  runtime image.
- With a step image or a default step image, the whole job runs there instead.
- If the runtime image is already your job image, leave `defaultStepImage`
  empty to avoid an extra container.
- `docker.stepImages: false` keeps every job in the runtime image, and ignores
  step `image:` too.

The runtime image must:

- Match the agent binary's architecture.
- Provide `/bin/sh`, `cp`, a writable workspace, and the tools and hooks your
  jobs need.
- Provide the Docker CLI and `setsid` when step images are enabled.

Configuration and hooks from `image` aren't copied into it.

Before you enable it:

- The pool's Docker daemon must be Docker Engine 29 or later.
- The chart switches the daemon to the containerd image store, replacing
  `overlay2` on Sysbox.
- Changing the setting rolls the pool's Pods, which start with empty image
  caches.
- CI tests the image mounts in Docker but not on Kata or Sysbox, so test those
  before rolling it out.

See [Agent runtime image](docs/wip_how_it_works.md#agent-runtime-image) in How
it works.

Both images are pulled only when missing, so a cached tag isn't refreshed for
each job. Coordinate with active jobs before changing either image or
upgrading runner Pods.

## Image pull caching

The `dind`, `kata` and `sysbox` Docker daemons can pull images through an
[OCI accelerator](https://github.com/buildkite/oci-accelerator), an HTTPS proxy
that caches registry content on its node's disk:

- Repeat pulls of layers and digest-addressed manifests come from the cache,
  across all runners and after runners are replaced.
- Image names and `docker login` don't change.
- Tags and pushes go to the upstream registry, which must approve access before
  the proxy serves cached content.

Enable the accelerator:

```yaml
ociAccelerator:
  enabled: true
  registries: [registry-1.docker.io, ghcr.io, public.ecr.aws]
```

Every `dind`, `kata` and `sysbox` entry then uses it. Set
`docker.ociAccelerator: false` on an entry to pull directly.

Each daemon sends all of its HTTPS traffic through the proxy:

- Only `registries` are cached, and other hosts are tunneled through unchanged.
- List hosts the proxy can't reach, such as in-cluster registries, in
  `noProxy`.
- Pulls fail while the proxy is unavailable.
- Job containers don't inherit the daemon's proxy settings.
- A NetworkPolicy admits only this release's runner Pods, if your network
  plugin enforces NetworkPolicy.

The proxy signs registry certificates with its own root CA. By default the
chart generates the CA on first install and keeps it across upgrades, and
runner Pods trust only its certificate. To rotate it or bring your own, see
[OCI accelerator CA](docs/wip_deployment.md#oci-accelerator-ca).

The chart runs `ociAccelerator.replicas` proxies (default 1) in a StatefulSet.
Cache size and resource requests apply **per replica**:

- Use at least two replicas to keep a proxy available during rolling updates
  and node replacement.
- In-flight pulls through a terminating proxy can still fail, even with
  several replicas.
- Without [peering](#peering), each proxy fills its cache from origin
  independently.
- The Service spreads connections, not image layers, so a long-lived
  connection keeps using the same replica.

### Peering

To let the proxies fetch cached content from one another, enable peering and
set the replica count:

```yaml
ociAccelerator:
  enabled: true
  replicas: 3
  peering:
    enabled: true
```

- The chart sets up peer discovery and mutual TLS with the release's CA, and
  runners keep using the same proxy Service.
- The NetworkPolicy allows peer traffic only between this release's proxies.
- Peering supports at most 32 replicas, the accelerator's peer limit.
- Changing the replica count, or switching peering on or off, rolls the
  proxies and empties their caches.

See the accelerator's
[peer discovery](https://github.com/buildkite/oci-accelerator/blob/v0.5.0/docs/deployment.md#peer-discovery)
docs for how peering works and its limits.

### Cache storage

- The cache is an `emptyDir` on the proxy's node, limited to `cache.size`
  (default 20Gi). It survives container restarts, but starts empty when the
  proxy Pod is replaced.
- The proxy requests `cache.size` of `ephemeral-storage`, so size it to fit
  beside runner Pods, or place the proxy with `nodeSelector` and `tolerations`.
- Keep `cache.maxBytes` below `cache.size`.
- Tag lookups are cached in memory for 30 seconds, so a tag pushed in one step
  can still resolve to its old digest in the next. To turn this off, set
  `OCI_ACCELERATOR_CACHE_MUTABLE_TTL: "0s"` in `ociAccelerator.extraEnv`.

Pass other `OCI_ACCELERATOR_*` settings through `ociAccelerator.extraEnv`. See
the accelerator's
[cache storage](https://github.com/buildkite/oci-accelerator/blob/v0.5.0/docs/deployment.md#cache-storage) and
[settings](https://github.com/buildkite/oci-accelerator/blob/v0.5.0/docs/settings.md) docs.

### Trust and placement

- The Docker daemons trust the accelerator's CA for every host, not only
  `registries`, because Docker doesn't read `/etc/docker/certs.d` for Docker
  Hub with the classic image store that `sysbox` uses.
- The proxy's node holds the CA private key that every accelerated daemon
  trusts, including those of `kata` and `sysbox` pools running untrusted jobs.
- A `dind` job can escape to its node, so with `dind` pools, keep the proxy off
  nodes `dind` runners can reach, using `ociAccelerator.nodeSelector` and
  `tolerations`.

See [OCI accelerator CA](docs/wip_deployment.md#oci-accelerator-ca) for how the
chart protects the key, and the accelerator's
[security model](https://github.com/buildkite/oci-accelerator/blob/v0.5.0/docs/deployment.md#security-model).

## Registry credentials

To pull private images, or to avoid Docker Hub's anonymous rate limits, give
the release registry credentials. They apply to every Pod and runner pool:

```yaml
registryCredentials:
  auths:
    - registry: https://index.docker.io/v1/
      username: myuser
      password: dckr_pat_...   # a Docker Hub access token
    - registry: ghcr.io
      username: myorg
      password: ghp_...
```

The chart stores them in one `kubernetes.io/dockerconfigjson` Secret,
`<release>-buildkite-operator-registry-credentials`. Values set this way are
also kept in Helm's release Secret. To manage the Secret yourself instead,
create it in the release namespace and set
`registryCredentials.existingSecret.name`:

```bash
kubectl create secret docker-registry registry-credentials \
  --namespace buildkite-runner-stack \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=myuser \
  --docker-password=dckr_pat_...
```

The credentials are used in two places:

- The kubelet uses them as `imagePullSecrets` to pull the images of every Pod
  the release runs: runners, the OCI accelerator, and the CA hook Jobs. Hooks
  run before the chart-managed Secret is created on install and after it is
  deleted on uninstall, so the hook Jobs use a copy,
  `<release>-buildkite-operator-registry-credentials-hook`, that Helm creates
  just before them and deletes once they finish.
- `dind`, `kata` and `sysbox` runners copy them into the Docker client
  configuration that jobs use. Docker daemons don't hold credentials
  themselves. The `docker` CLI sends them with each pull, run and build.
  `standard` runners have no Docker daemon, so they only get `imagePullSecrets`.

Every `dind`, `kata` and `sysbox` runner Pod has a writable Docker client
configuration directory, `/etc/buildkite-agent/docker`, set as `DOCKER_CONFIG`
for the agent and, with ephemeral agents, for the supervisor and every agent
container it starts. It lasts as long as the Pod and is shared by all of its
jobs, persistent or ephemeral, so a job's own `docker login` and buildx state
carry over to later jobs on that Pod. Credentials are copied in when the Pod
starts. Any job can read them, so use tokens with only the access the
pools' jobs need.

Changing chart-managed credentials rolls the runner and proxy Pods. After
changing an existing Secret, restart those Deployments yourself. Pulls through
the [OCI accelerator](#image-pull-caching) use the credentials unchanged.

## Development

```bash
make test-helm        # lint and render the standalone chart
make helm-examples    # update the chart's rendered examples
make test-supervisor  # run the ephemeral-agent supervisor against Docker
make test-step-image  # run step images against Docker
make test-helm-e2e    # install and uninstall the chart in isolated Kind
make lint             # golangci-lint
make test             # Go tests and generated-file checks
make install-hooks    # use the Git hooks in .githooks
```

Each directory under `charts/buildkite-operator/examples` pairs a
`values.yaml` with the `rendered.yaml` that `helm template` produces from it
and the `NOTES.txt` that `helm install` prints for it, so chart changes show up
as manifest and install-notes diffs in review. The pre-commit hook
installed by `make install-hooks` renders the staged chart and stops the commit
if the staged examples don't match. Unstaged changes are ignored.

CI runs the checks, and also fails if the rendered examples are out of date.
The end-to-end check deletes its isolated Kind cluster when it finishes, which
may clear the current kubeconfig context.

The chart E2E test temporarily pins Kind 0.30's Kindnet image by digest because
CI's kernel lacks `CONFIG_NETFILTER_NETLINK_GLUE_CT`, required by newer policy
engines to recognize allowed connections' replies. This changes only the test
cluster's CNI. The chart's NetworkPolicy and peer-isolation checks are
unchanged. Remove the pin once CI provides that kernel capability.

## Chart releases

Buildkite publishes tagged chart releases to the public Docker Hub repository
`buildkite/buildkite-operator-chart`, using the OCI registry at
`registry-1.docker.io`. No GitHub Actions workflow is required. Publication
waits for all pipeline checks on the tagged commit to pass, including the chart
E2E test.

### One-time setup

- Enable **Build tags** in the Buildkite pipeline's GitHub settings. Ensure
  branch filters and pipeline-level conditionals allow tag builds.
- Use the public Docker Hub repository `buildkite/buildkite-operator-chart`.
  Keep chart releases in this dedicated repository, not a container-image
  repository with overlapping version tags.
- Create a Buildkite Secret named `DOCKERHUB_TOKEN` in the agent cluster. Use a
  Docker Hub organization access token for `buildkite` with **Read & Write**
  access to `buildkite-operator-chart`, without delete access. The publisher
  uses the fixed username `buildkite`, so no username secret is needed. Do not
  put the token in pipeline YAML or repository files.
- Restrict secrets to this pipeline and trusted build contexts using
  [agent access policies](https://buildkite.com/docs/pipelines/security/secrets/buildkite-secrets/access-policies).
  These policies support pipeline and branch claims, not step-key or tag
  claims. The release step's `if` condition is not a secret access boundary.
  Do not grant publishing credentials to untrusted pull request builds. If
  they share this pipeline, isolate release access with an appropriately
  restricted agent queue or separate release pipeline before enabling the
  secrets.
- Protect `chart-v*` tags in GitHub so only trusted maintainers can create,
  change, or delete them: tagged repository code runs with publishing access.

### Publishing

Merge the chart changes and version bump first, then tag that commit
`chart-v<version>`, for example `chart-v0.20.0` for `version: 0.20.0` in
`charts/buildkite-operator/Chart.yaml`, and push the tag. Only stable
`major.minor.patch` releases are supported. `appVersion` is not used as the
release version.

The release script, `.buildkite/publish-chart.py`, rejects mismatched versions
and existing published versions. Registry authentication and network errors
fail the release rather than being treated as a missing version. Buildkite
serializes publishing jobs so two builds cannot pass the existing-version check
concurrently. Docker Hub tags are mutable by default, so do not overwrite
releases with other publishing tools.

The script packages the chart, pushes it, then pulls it by its published OCI
digest and compares the downloaded package with the original. The build log
records the digest and verification result. Helm's login credentials and chart
packages are kept in a temporary directory removed when the script exits.

If a job fails after pushing, the version may already be published. Retrying
will refuse to overwrite it: inspect the package and digest before proceeding,
and publish a new chart version if a correction is needed. Do not delete a
release just to make a retry succeed.

### Installing a release

The chart repository is public, so you don't need Docker Hub credentials or a
registry login to install a release:

```bash
helm upgrade --install buildkite-operator \
  oci://registry-1.docker.io/buildkite/buildkite-operator-chart \
  --version 0.20.0 \
  --namespace buildkite-runner-stack --create-namespace \
  --values values.yaml
```

The values file must provide the runner pools described in
[Quickstart](#quickstart) and the token Secret references described in
[Production secret management](docs/wip_deployment.md#production-secret-management),
and KEDA must already be installed. Any private container images used by your
configuration still need their own pull credentials. For digest-pinned
installs, replace the chart URL with the `oci://…@sha256:…` reference from the
release log and omit `--version`.

Run `python3 hack/test_publish_chart.py` to test release handling locally. It
uses real Helm chart packaging with simulated registry and credential services.
It does not retrieve secrets or publish to Docker Hub.

## License

MIT — see [LICENSE](LICENSE).
