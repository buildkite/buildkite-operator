# Buildkite runner stack for Kubernetes

> [!IMPORTANT]
> This chart is still under heavy development:
>
> - Values, defaults and the resources the chart creates can change in any
>   release, including minor ones, without a migration path.
> - Pin the chart version, and review the changes before you upgrade.
> - Test it in a non-production cluster before you rely on it.
>
> Please report bugs and feedback as GitHub issues.

This repository contains a standalone Helm chart for running a Buildkite
runner stack on Kubernetes. One chart release can serve several Buildkite
queues. Each runner pool has a `Deployment` of runner Pods and KEDA scaling.
Pools can share a queue, and all pools in a release share one token Secret.

The stack includes:

- Runner pools that KEDA [scales](#autoscaling) on each queue's job count.
- A choice of [runtimes](#runtimes) for each pool.
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

The chart's
[deletion-cost admission policy](docs/appendices.md#deletion-cost-admission-policy),
which it installs by default, needs Kubernetes 1.30 or later. Some runtimes
need more. See [Runtimes](#runtimes).

## Install

Add a runner pool under `runnerPools` for each Buildkite queue, with its maximum
runner count, and provide the cluster agent token. The pool name (`linux` below)
is used in resource names:

```bash
export BUILDKITE_AGENT_TOKEN='<agent-token>'

helm upgrade --install buildkite-operator \
  oci://registry-1.docker.io/buildkite/buildkite-operator-chart \
  --version 0.24.0 \
  --namespace buildkite-runner-stack \
  --create-namespace \
  --set-string runnerPools.linux.queue=<queue> \
  --set runnerPools.linux.maxReplicas=<maximum> \
  --set-string agentToken.value="$BUILDKITE_AGENT_TOKEN"
```

- The chart repository is public, so you don't need Docker Hub credentials to
  install it.
- Helm stores supplied values in its release data. For production, create the
  token Secrets yourself. See
  [Production secret management](docs/appendices.md#production-secret-management).
- Private images in your configuration need their own pull credentials. See
  [Registry credentials](#registry-credentials).
- To pin the chart by digest, use
  `oci://registry-1.docker.io/buildkite/buildkite-operator-chart@sha256:<digest>`
  and omit `--version`.

<details>
<summary>Install from a checkout of this repository</summary>

```bash
helm upgrade --install buildkite-operator ./charts/buildkite-operator \
  --namespace buildkite-runner-stack \
  --create-namespace \
  --set-string runnerPools.linux.queue=<queue> \
  --set runnerPools.linux.maxReplicas=<maximum> \
  --set-string agentToken.value="$BUILDKITE_AGENT_TOKEN"
```

</details>

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
- Pools can share a Buildkite queue. Set a [scaling formula](#scaling-formula)
  to give each pool a share of its demand.
- With no pools, the chart installs nothing.

Because `runnerPools` is a map, a later values file can change one pool
(`linux-kata: {maxReplicas: 25}`) or remove it (`build-sysbox: null`) without
restating the others.

Each pool's `Deployment` and `ScaledObject` are named `<release>-<pool>`, and
all pools in a release share one token. Queues in a different Buildkite cluster
need a different token, so put them in a separate release. See
[Resources the chart creates](docs/appendices.md#resources-the-chart-creates).

See [Settings reference](#settings-reference) for every pool setting.

### Turning a pool off

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
[Installing Kata and Sysbox](docs/appendices.md#installing-kata-and-sysbox).

### Ephemeral standard agents

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

### Persistent Sysbox agents

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

### Persistent Docker-in-Docker agents

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

### Ephemeral Kata agents

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
- Each Pod runs in its own VM, which separates jobs from the node more strongly
  than the other runtimes.

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

The Docker and Docker Compose plugins' `mount-buildkite-agent` option works. See
[Bind mounts](docs/appendices.md#bind-mounts) in the appendices.

## Ephemeral agents

`ephemeralAgent` controls the Buildkite agent, not the Pod:

- Runner Pods always persist across jobs, and only autoscaling adds or removes
  them.
- With `dind`, `kata` and `sysbox`, Docker data and the workspace live in the
  Pod and are discarded when it's removed.

By default (`ephemeralAgent: false`), one agent registers when its Pod starts
and runs job after job, so whatever a job leaves behind is there for the next.

With `ephemeralAgent: true`, the agent disconnects after each job, and a newly
registered agent named `<pod>-<suffix>` replaces it with a clean workspace. On
SIGTERM, the current agent finishes its job and no further agent starts. See
[Ephemeral agents](docs/appendices.md#ephemeral-agents) in the appendices.

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

### Isolation between jobs

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
[Step images](docs/appendices.md#step-images) in the appendices.

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

Before you enable it, check the runtime image requirements and Docker daemon
changes in [Agent runtime image](docs/appendices.md#agent-runtime-image).

## Autoscaling

KEDA polls Buildkite's Agent Metrics API and sizes each runner pool between
`minReplicas` (one by default) and `maxReplicas`. By default, the pool targets
its queue's `scheduled + running` job count.

Scaling in happens in one of two ways:

- While the scaling metric is active, the HPA removes runners only after the
  lower count has lasted `scaleDownStabilizationWindowSeconds`.
- Once the scaling metric is inactive, a pool with `minReplicas: 0` scales to
  zero after `cooldownPeriod`, removing every remaining runner at once. With
  the default formula, the metric is inactive when the queue has no
  scheduled or running jobs.

When a runner is removed:

- Runner Pods with idle agents are removed first where possible. See
  [Scale-in preference](#scale-in-preference).
- The agent finishes its running job on its first SIGTERM, for up to
  `terminationGracePeriodSeconds`.
- Terminating Pods can briefly run alongside their replacements, so a pool can
  have more than `maxReplicas` Pods for a short time.

KEDA stays installed when you uninstall a release of this chart, and several
releases in the cluster can share it.

### Scaling formula

`scalingFormula` is a KEDA expression using the named queue metrics `scheduled`
and `running`. It defaults to `scheduled + running` and must return a single
numeric value, which sets the desired runner count before rounding, replica
bounds and scaling policies.

Set the formula under `defaults` or override it per pool. For example, split
a queue's capacity target between two pools:

```yaml
runnerPools:
  primary:
    queue: builds
    maxReplicas: 75
    scalingFormula: "(scheduled + running) * 0.75"
  secondary:
    queue: builds
    maxReplicas: 25
    scalingFormula: "(scheduled + running) * 0.25"
```

- With 40 scheduled-or-running jobs, the pools target 30 and 10 runners,
  subject to their replica bounds and scaling policies.
- Pools scale independently. They do not normalize shares or redistribute
  capacity if another pool reaches its limit or cannot schedule runners.
- Agents compete for jobs from the same queue. Capacity shares do not
  guarantee job assignment shares, and rounding and minimum replicas can
  increase total capacity above the queue's demand.

The chart fixes KEDA's `target` to `"1"`, `activationTarget` to `"0"` and
`metricType` to `AverageValue`. A positive formula result activates scaling
from zero. With `minReplicas: 0`, a nonpositive result allows scale-to-zero
after the cooldown.

The chart requires a nonempty formula string. KEDA validates the expression.
See KEDA's
[scaling modifiers reference](https://keda.sh/docs/2.20/reference/scaledobject-spec/#scalingmodifiers)
for expression syntax.

### Scale-in preference

Each runner Pod's sidecar marks the Pod busy or idle with annotations, so the
ReplicaSet prefers removing runner Pods with idle agents. This is best-effort,
and Kubernetes can still remove a busy one. See
[Scale-in and node autoscaling](docs/appendices.md#scale-in-and-node-autoscaling).

### Node autoscaling

If your cluster runs
[Cluster Autoscaler](https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler),
which this chart doesn't install, the same annotations stop it removing nodes
with busy agents, and let it remove nodes whose agents are idle. This is also
best-effort. See
[Scale-in and node autoscaling](docs/appendices.md#scale-in-and-node-autoscaling).

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

The chart stores them in a `kubernetes.io/dockerconfigjson` Secret,
`<release>-buildkite-operator-registry-credentials`, and Helm also keeps them
in its release Secret. To manage the Secret yourself, create it in the release
namespace and set `registryCredentials.existingSecret.name`:

```bash
kubectl create secret docker-registry registry-credentials \
  --namespace buildkite-runner-stack \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=myuser \
  --docker-password=dckr_pat_...
```

How the credentials are used:

- The kubelet pulls every Pod the release runs with them as
  `imagePullSecrets`: runners, the accelerator and the CA hook Jobs.
- `dind`, `kata` and `sysbox` runners also copy them into the Docker client
  configuration, and the `docker` CLI sends them with each pull, run and build.
- `standard` runners have no Docker daemon, so they only get
  `imagePullSecrets`.

On `dind`, `kata` and `sysbox` runners, the Docker client configuration:

- Lasts as long as the Pod, so a job's own `docker login` and buildx state
  carry over to later jobs on that Pod, persistent or ephemeral.
- Gets the credentials copied in when the Pod starts.
- Is readable by any job, so use tokens with only the access the pools' jobs
  need.

See [Registry credentials](docs/appendices.md#registry-credentials) in
the appendices.

When credentials change:

- Changing chart-managed credentials rolls the runner and accelerator Pods.
- After changing an existing Secret, restart the runner Deployments and the
  accelerator StatefulSet yourself.
- Pulls through [OCI Accelerator](#image-pull-caching) use the credentials
  unchanged.

## Image pull caching

The `dind`, `kata` and `sysbox` Docker daemons can pull images through
[OCI Accelerator](https://github.com/buildkite/oci-accelerator), an HTTPS proxy
that caches registry content on its node's disk:

- Repeat pulls of layers and digest-addressed manifests come from the cache,
  across all runners and after runners are replaced.
- Image names and `docker login` don't change.
- Tags and pushes go to the upstream registry, which must approve access before
  the accelerator serves cached content.

Enable OCI Accelerator:

```yaml
ociAccelerator:
  enabled: true
  registries: [registry-1.docker.io, ghcr.io, public.ecr.aws]
```

Every `dind`, `kata` and `sysbox` pool then uses it. Set
`docker.ociAccelerator: false` on a pool to pull directly.

Each daemon sends all of its HTTPS traffic through the accelerator:

- Only `registries` are cached, and other hosts are tunneled through unchanged.
- List hosts the accelerator can't reach, such as in-cluster registries, in
  `noProxy`.
- Pulls fail while the accelerator is unavailable.
- Job containers don't inherit the daemon's proxy settings.
- A NetworkPolicy allows this release's runner Pods to reach the accelerator
  on port 5128, if your network plugin enforces NetworkPolicy.

The accelerator signs registry certificates with its own root CA. By default
the chart generates the CA on first install and keeps it across upgrades, and
runner Pods trust only its certificate. To rotate it or bring your own, see
[OCI Accelerator CA](docs/appendices.md#oci-accelerator-ca).

The chart runs `ociAccelerator.replicas` accelerator replicas (default 1) in a
StatefulSet. Cache size and resource requests apply **per replica**:

- Use at least two replicas to keep the accelerator available during rolling
  updates and node replacement.
- In-flight pulls through a terminating replica can still fail, even with
  several replicas.
- Without [peering](#peering), each replica fills its cache from origin
  independently.
- The Service spreads connections, not image layers, so a long-lived
  connection keeps using the same replica.

### Peering

To let accelerator replicas fetch cached content from one another, enable
peering and set the replica count:

```yaml
ociAccelerator:
  enabled: true
  replicas: 3
  peering:
    enabled: true
```

- Peering supports at most 32 replicas, OCI Accelerator's peer limit.
- Changing the replica count, or switching peering on or off, rolls the
  accelerator and empties its caches.

See
[OCI Accelerator resources and peering](docs/appendices.md#oci-accelerator-resources-and-peering)
for cache sizing and peering details.

### Metrics

Set `ociAccelerator.metrics.remote: true` to expose the Prometheus endpoint
at each accelerator Pod's IP on port 9090. Use
`ociAccelerator.networkPolicy.metricsFrom` to admit your collectors, and
`ociAccelerator.podAnnotations` for collector discovery. See
[OCI Accelerator metrics](docs/appendices.md#oci-accelerator-metrics) for
configuration and access restrictions.

### Trust and placement

The Docker daemons trust OCI Accelerator's CA for every host, and the
accelerator's node holds its private key. With `dind` pools, keep the
accelerator off nodes `dind` runners can reach, using
`ociAccelerator.nodeSelector` and `tolerations`. See
[OCI Accelerator CA](docs/appendices.md#oci-accelerator-ca).

## Security

A summary of the chart's security boundaries:

- `dind` runs a privileged Docker daemon, so its jobs can escape to their node.
  See [Privileged Docker-in-Docker](#privileged-docker-in-docker).
- `kata` runs each Pod in its own VM, and `sysbox` runs an unprivileged Docker
  daemon, so both separate jobs from the node more strongly than `dind`.
- Ephemeral agents keep jobs' state apart, but they aren't a security boundary.
  See [Isolation between jobs](#isolation-between-jobs).
- Any job can read its Pod's registry credentials, so use narrowly scoped
  tokens. See [Registry credentials](#registry-credentials).
- With OCI Accelerator, the Docker daemons trust its CA for every host, so keep
  the accelerator off nodes `dind` runners can reach. See
  [Trust and placement](#trust-and-placement).
- Each runner Pod's deletion-cost sidecar holds a Kubernetes API token, which an
  admission policy limits. See
  [Deletion-cost admission policy](docs/appendices.md#deletion-cost-admission-policy).

## Settings reference

Each runner pool takes these settings, directly or from `defaults`:

| Setting | Description |
| --- | --- |
| `queue` | (required) Buildkite queue key the agents serve and scale on. |
| `maxReplicas` | (required) Upper bound on runners. |
| `minReplicas` | (default `1`) Runners kept when the queue is idle. |
| `runtime` | (default `standard`) `standard`, `dind`, `kata` or `sysbox`. See [Runtimes](#runtimes). |
| `ephemeralAgent` | (default `false`) Replace the agent after every job, with a clean workspace. The Pod persists. See [Ephemeral agents](#ephemeral-agents). |
| `terminationGracePeriodSeconds` | (default `3600`) Longest time an agent may take to drain its job. |
| `rollingUpdate.maxUnavailable` | (default `0`) Maximum unavailable runner Pods during a rollout, as a nonnegative count or percentage string from `"0%"` to `"100%"`. |
| `rollingUpdate.maxSurge` | (default `1`) Maximum extra non-terminating runner Pods above the desired replica count during a rollout, as a nonnegative count or percentage string. |
| `pollingInterval` | (default `10`) Seconds between KEDA's checks of the queue. |
| `scalingFormula` | (default `scheduled + running`) KEDA expression for the desired runner count using the named metrics `scheduled` and `running`. See [Scaling formula](#scaling-formula). |
| `cooldownPeriod` | (default `60`) Seconds the scaling metric must be inactive before KEDA scales a pool with `minReplicas: 0` to zero. See [Autoscaling](#autoscaling). |
| `scaleDownStabilizationWindowSeconds` | (default `60`) Seconds the HPA waits before removing runners after the desired count drops (0–3600), except when scaling to zero. |
| `image` | (default `buildkite/agent:4`) Agent image. It needs `/bin/sh`, except for persistent `standard` agents. |
| `resources` | (default none) Kubernetes `requests` and `limits` for the agent container. With `dind`, `kata` or `sysbox` and `ephemeralAgent`, agents run inside the Docker daemon, so use [`docker.resources`](#docker-settings) instead. |
| `docker` | Docker daemon settings for `dind`, `kata` and `sysbox`. See [Docker settings](#docker-settings). |

For faster rollouts with spare cluster capacity, increase `maxSurge` while
keeping `maxUnavailable: 0`. Set it for every pool or override one pool:

```yaml
defaults:
  rollingUpdate:
    maxSurge: 20

runnerPools:
  linux:
    queue: linux
    maxReplicas: 200
    rollingUpdate:
      maxSurge: 30
```

At least one budget must be nonzero. Raising `maxUnavailable` lets available
runner capacity drop during the rollout. Terminating Pods can still consume
resources while their agents drain jobs, beyond the `maxSurge` budget.

### Docker settings

`dind`, `kata` and `sysbox` runners also take Docker daemon settings under
`docker`:

| Setting | Description |
| --- | --- |
| `docker.image` | (default `docker:29.7.2-dind`) Docker daemon image. |
| `docker.resources` | (default 2 CPUs, 4Gi memory and 15Gi disk requested, limited to 4 CPUs, 8Gi and 50Gi) Kubernetes `requests` and `limits` for the Docker daemon. With `ephemeralAgent`, they also bound the agent containers. |
| `docker.storage.data` | (default `40Gi`) Size limit of the `emptyDir` for Docker's data in `/var/lib/docker`. |
| `docker.storage.workspace` | (default `10Gi`) Size limit of the `emptyDir` for the `/buildkite` workspace. |
| `docker.ociAccelerator` | (default `true`) Pull through [OCI Accelerator](#image-pull-caching) when it is enabled. |
| `docker.stepImages` | (default `true`) Run steps that set `image:` in that image. See [Step images](#step-images). |
| `docker.defaultStepImage` | (default none) Image for steps without `image:`. See [Step images](#step-images). |
| `docker.agentRuntimeImage` | (default none) Separate runtime image for ephemeral agents. See [Agent runtime image](#agent-runtime-image). |

## Contributing

See [Maintainers](docs/maintainers.md) for development and for releasing
the chart.

## License

MIT — see [LICENSE](LICENSE).
