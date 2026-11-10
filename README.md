# buildkite-operator

This repository contains a standalone Helm chart for running a Buildkite
runner stack on Kubernetes. One chart release can serve several Buildkite
queues. Each gets its own runner pool (a `Deployment` of runner Pods) and KEDA
scaling, and they share one token Secret.

The stack includes:

- Runner pools that KEDA [scales](#autoscaling) on each queue's job count.
- A choice of [isolation runtimes](#runner-isolation) for each pool.
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
[deletion-cost admission policy](#scale-in-preference), native sidecars for
the [`dind`, `kata` and `sysbox` runtimes](#runner-isolation), and Kata or
Sysbox installed on the nodes for those runtimes.

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

Each runner pool under `runnerPools` serves one Buildkite queue and inherits
every setting from `defaults`, overriding any of them. For example, a values
file serving a Kata pool and a Sysbox pool with ephemeral agents:

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

Every pool needs `queue` and `maxReplicas`. Pool names are lowercase letters,
digits and hyphens. Each Buildkite queue may appear in only one pool, because
KEDA scales a pool on its queue's whole job count. Because `runnerPools` is a
map, a later values file can change one pool (`linux-kata: {maxReplicas: 25}`)
or remove it (`build-sysbox: null`) without restating the others. With no
pools, the chart installs nothing.

Each pool is a `Deployment` whose Pods are labeled
`buildkite.com/runner-pool: <pool>`, and a `ScaledObject` that scales it, both
named `<release>-<pool>`. The token Secret, KEDA `TriggerAuthentication`, and
deletion-cost permissions and scripts are shared by all pools in a release.
Queues in a different Buildkite cluster need a different token, so they use a
separate release.

Chart versions before 0.20.0 called this map `queues`. Rename the key to
`runnerPools` in your values when upgrading. The entries inside are unchanged,
and so are the resource names. The chart fails rather than install with
`queues` still set, since ignoring it would remove every runner. Upgrade with
your complete migrated values file and `--reset-values`. Without a values file,
use `--reset-then-reuse-values --set queues=null` and set each pool under
`runnerPools`. `--reuse-values` can't migrate: Helm restores the release's
stored `queues` even when you pass `--set queues=null`.

| Setting | Default | Description |
| --- | --- | --- |
| `queue` | required | Buildkite queue key the agents serve and scale on. |
| `maxReplicas` | required | Upper bound on runners. |
| `minReplicas` | `1` | Runners kept when the queue is idle. |
| `runtime` | `standard` | `standard`, `dind`, `kata` or `sysbox`. See [Runner isolation](#runner-isolation). |
| `ephemeralAgent` | `false` | Replace the agent after every job, with a clean workspace. The Pod persists. See [Ephemeral agents](#ephemeral-agents). |
| `terminationGracePeriodSeconds` | `3600` | Longest time an agent may take to drain its job. |
| `pollingInterval`, `cooldownPeriod` | `10`, `60` | KEDA polling interval, and how long the queue must be fully idle before KEDA scales a pool with `minReplicas: 0` to zero, in seconds. KEDA removes every remaining runner at once, without waiting for `scaleDownStabilizationWindowSeconds`. To keep an idle pool longer, raise `cooldownPeriod`. |
| `scaleDownStabilizationWindowSeconds` | `60` | Seconds the HPA waits before removing runners after the job count drops (0–3600), while at least one runner is still needed. Covers dips between dependent steps. |
| `image`, `resources` | `buildkite/agent:4` | Agent image, and requests and limits for the agent container. With `dind`, `kata` or `sysbox` and `ephemeralAgent`, `resources` is ignored: agents run as containers inside the Docker daemon and share its `docker.resources` budget. With `standard` and `ephemeralAgent`, the image also needs `/bin/sh`. |
| `docker` | `docker:29.7.2-dind` | Docker daemon image, resources and storage for `dind`, `kata` and `sysbox`. With `ephemeralAgent`, `docker.resources` also bounds the agent containers. `docker.ociAccelerator` (default `true`) pulls through the [OCI accelerator](#image-pull-caching) when it is enabled. `docker.stepImages` (default `true`) runs steps that set `image:` in that image. See [Step images](#step-images). |

### Examples

Ephemeral standard agents. Every job gets a fresh agent and an empty workspace
in a plain Pod with no Docker daemon. The container keeps running, so files
outside the workspace carry over between jobs:

```yaml
runnerPools:
  linux:
    queue: linux
    ephemeralAgent: true
    maxReplicas: 10
```

Persistent Sysbox agents. Each Pod runs one long-lived agent next to an
unprivileged Docker daemon, so containers, volumes, checkouts and caches carry
over between jobs. The pool scales to zero when the queue is idle:

```yaml
runnerPools:
  docker-builds:
    queue: docker-builds
    runtime: sysbox
    minReplicas: 0
    maxReplicas: 4
```

Persistent Docker-in-Docker agents, for trusted jobs on clusters that can't
run Kata or Sysbox. Each Pod runs one long-lived agent next to a privileged
Docker daemon, on any node. See
[Privileged Docker-in-Docker](#privileged-docker-in-docker) before using it:

```yaml
runnerPools:
  docker:
    queue: docker
    runtime: dind
    maxReplicas: 4
```

Ephemeral Kata agents. Each job runs in a fresh agent container inside a
VM-isolated Pod. Afterwards its containers, networks, volumes and workspace are
removed, while Docker's image and build caches are kept:

```yaml
runnerPools:
  untrusted:
    queue: untrusted
    runtime: kata
    ephemeralAgent: true
    maxReplicas: 6
```

To turn a pool off, comment out or delete it, or set it to `null` in a
later values file, for example `helm upgrade ... -f values.yaml -f off.yaml`
with:

```yaml
# off.yaml
runnerPools:
  untrusted: null
```

Helm then removes the pool's `Deployment` and `ScaledObject`, and its agents
drain their current jobs. `maxReplicas` must be at least 1. To keep a pool
without idle runners, set `minReplicas: 0` instead.

## Autoscaling

KEDA polls Buildkite's Agent Metrics API. For each runner pool it scales for
`scheduled + running` jobs, keeps one runner warm by default, and scales up to
the pool's `maxReplicas`. While jobs are scheduled or running, the HPA
removes runners only after the lower count has persisted for
`scaleDownStabilizationWindowSeconds`, because jobs blocked on `depends_on` are
not counted until their dependencies finish. Once the queue has no scheduled or
running jobs, a pool with `minReplicas: 0` scales to zero after
`cooldownPeriod` instead.

KEDA's HPA chooses scale-in victims without confirming that a selected agent is
idle. The agent drains a running job on its first SIGTERM, bounded by
`terminationGracePeriodSeconds`. The configured maximum bounds desired
replicas, but terminating Pods may briefly overlap replacement capacity. KEDA
stays installed when you uninstall a release of this chart, and several
releases in the cluster can share it.

### Scale-in preference

Each runner Pod includes a small sidecar that polls the agent's
local `/status.json` endpoint every second. On each change between busy and
idle it patches two annotations together, retrying until the patch succeeds:

| Agent | `controller.kubernetes.io/pod-deletion-cost` | `cluster-autoscaler.kubernetes.io/safe-to-evict` |
| --- | --- | --- |
| Busy or unknown (including at startup) | `"100"` | `"false"` |
| Idle | removed | `"true"` |

The deletion cost makes the ReplicaSet prefer removing idle agents. This is
best-effort. Kubernetes can still select a busy Pod, and deletion cost does not
protect against node drains or evictions. The sidecar is always enabled
because it is part of the chart's autoscaling behavior, and its Python image is
pinned by digest. The sidecar receives the only Kubernetes API token in the Pod.

Because Deployment Pod names are generated, the sidecar's Role can't be limited
to its own Pod, so it lets the token patch every Pod in the release namespace.
A job that escapes to its node can read the tokens of the Pods there, and could
use one to change another runner Pod's image and take it over, or with the OCI
accelerator enabled, the proxy's. The chart
therefore also installs a `ValidatingAdmissionPolicy` and binding, both named
`<namespace>-<release>-buildkite-operator-deletion-cost`. The kubelet binds
each sidecar's token to its Pod, and the API server records the Pod's name in
the token's user info. The policy uses this to allow the sidecar's patches only
to its own Pod, and only to the two annotations above: the spec, labels,
finalizers, owner references and every other annotation must stay the same.

The policy and binding are cluster-scoped, so installing the chart needs
permission to create them, and Kubernetes 1.30 or later. If you can't grant
that, set `deletionCost.admissionPolicy.enabled: false`. The sidecar then
works the same, but its token can change any Pod in the namespace, so install
the chart in a namespace dedicated to runners.

### Node autoscaling

When [Cluster Autoscaler](https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler)
removes an underused node, it evicts the node's Pods and caps their graceful
termination at its `--max-graceful-termination-sec` (600 seconds by default),
well below the chart's default `terminationGracePeriodSeconds`. A busy agent's
`safe-to-evict: "false"` stops Cluster Autoscaler from removing its node, so
running jobs are not cut short.

Idle agents are marked `safe-to-evict: "true"` rather than left unannotated.
`dind`, `kata` and `sysbox` runners use disk-backed `emptyDir` volumes for
Docker data and the workspace, and Cluster Autoscaler's default
`--skip-nodes-with-local-storage=true` would otherwise never remove their
nodes. This is also best-effort: an agent that accepts a job after Cluster
Autoscaler checks its node but before eviction is still bounded by
`--max-graceful-termination-sec`. Node drains outside Cluster Autoscaler,
such as `kubectl drain` or spot interruptions, ignore the annotation.

## Runner isolation

Set `runtime` in `defaults` or on a runner pool to choose its isolation profile:

| Value | Runner Pod |
| --- | --- |
| `standard` (default) | A Buildkite agent in a regular Kubernetes Pod, with no Docker daemon. |
| `dind` | An agent and privileged Docker native sidecar in a regular Pod on any node. Not isolation. See [Privileged Docker-in-Docker](#privileged-docker-in-docker). |
| `kata` | An agent and privileged Docker native sidecar inside the `kata-qemu-runtime-rs` VM RuntimeClass. |
| `sysbox` | An agent and unprivileged Docker native sidecar using the `sysbox-runc` RuntimeClass and Kubernetes user namespaces. |

Different entries in one release can use different profiles. `standard` and
`dind` need nothing installed. Kata and Sysbox are host runtimes, so the chart
deliberately does not install them or modify containerd. Like KEDA, they are
cluster-wide installs, done once per cluster before installing the chart:

| `runtime` | RuntimeClass | Installer | Nodes |
| --- | --- | --- | --- |
| `kata` | `kata-qemu-runtime-rs` | [kata-deploy](https://github.com/kata-containers/kata-containers/tree/main/tools/packaging/kata-deploy) | KVM-capable, labeled and tainted (`NoSchedule`) `experiments.buildkite.com/runtime=kata` |
| `sysbox` | `sysbox-runc` | [sysbox-deploy-k8s](https://github.com/nestybox/sysbox/blob/master/docs/user-guide/install-k8s.md) | Kubernetes user namespaces support, labeled and tainted (`NoSchedule`) `experiments.buildkite.com/runtime=sysbox` |

Each installer must target the runtime's nodes and tolerate their
`experiments.buildkite.com/runtime=<kata|sysbox>:NoSchedule` taint. Neither
does by default. With node autoscaling, the installer must also run on newly
added nodes before runners are scheduled there. For kata-deploy, add to its
Helm values:

```yaml
nodeSelector:
  experiments.buildkite.com/runtime: kata
tolerations:
  - {key: experiments.buildkite.com/runtime, operator: Equal, value: kata, effect: NoSchedule}
```

For Sysbox, label the nodes `sysbox-install=yes` as upstream requires, and
patch the `sysbox-deploy-k8s` DaemonSet, for example as a Kustomize patch.
The tolerations list replaces upstream's, so keep its
`sysbox-runtime=not-running` toleration:

```yaml
spec:
  template:
    spec:
      nodeSelector:
        experiments.buildkite.com/runtime: sysbox
      tolerations:
        - {key: sysbox-runtime, operator: Equal, value: not-running, effect: NoSchedule}
        - {key: experiments.buildkite.com/runtime, operator: Equal, value: sysbox, effect: NoSchedule}
```

The `dind`, `kata` and `sysbox` profiles require Kubernetes native sidecars.
Sysbox additionally requires Kubernetes user namespaces. Their Docker data and
workspace are Pod-local and are discarded when a runner Pod is removed.

The Docker daemon resolves bind-mount sources in its own container, which
shares only the `/buildkite` workspace with the agent. Jobs can bind-mount
checkouts and other paths under `/buildkite` into their containers, but not
files elsewhere in the agent's container. So that the Docker and Docker Compose
plugins' `mount-buildkite-agent` works, each agent copies its binary to
`/buildkite/bin/buildkite-agent` and puts that directory first on `PATH`,
where the plugins look for it. The agent image therefore needs `/bin/sh`.

### Privileged Docker-in-Docker

`runtime: dind` is for clusters that can't run Kata or Sysbox but whose jobs
need Docker. The Pod runs the same Docker daemon sidecar as `kata` and
`sysbox`, privileged and without a RuntimeClass, so it schedules on any node.

> [!WARNING]
> A privileged container has host-level access to its node: it can see host
> devices, load kernel modules and escape to the host. `dind` is not isolation.
> Only run trusted jobs on `dind` runner pools, and don't share their nodes with
> workloads those jobs must not reach.

The namespace must allow privileged Pods. With Pod Security Admission, label it
for the `privileged` level, for example
`kubectl label namespace <namespace> pod-security.kubernetes.io/enforce=privileged`.
`kata` runners need the same, because their Docker daemon is privileged inside
the VM. The chart adds no node selector or toleration for `dind`, so its Pods
can land on any node. Dedicated nodes for `dind` runners aren't configurable
yet.

### Ephemeral agents

`ephemeralAgent` controls the Buildkite agent, not the Pod. Runner Pods always
persist across jobs. Only autoscaling adds or removes them.

By default (`ephemeralAgent: false`) agents are persistent: one agent registers
when its Pod starts and runs job after job, so whatever a job leaves behind is
still there for the next. With `ephemeralAgent: true`, the agent disconnects
after one job and is replaced by a newly registered agent, named
`<pod>-<suffix>`, with a clean workspace. How depends on the runtime:

- `standard`: the agent container runs a small loop instead of the agent
  itself. It empties the build and plugin directories, runs
  `buildkite-agent start --disconnect-after-job`, and repeats when the agent
  exits. The container is never restarted, so the kubelet's restart backoff
  does not slow down the next job. The agent image needs `/bin/sh`.
- `dind`, `kata`, `sysbox`: a supervisor container starts each agent as a fresh
  container inside the Pod's Docker daemon with `--disconnect-after-job`.
  After each job it removes the job's containers, networks and volumes, clears
  the `/buildkite` workspace, and starts the next agent.

If cleanup fails, no new agent starts until it succeeds. Scaling in, upgrades
and node scale-down behave as for persistent agents: on SIGTERM the current
agent finishes its job, bounded by `terminationGracePeriodSeconds`, and no
further agent starts. If the deletion-cost sidecar polls while one agent is
being replaced by the next, it finds no agent status and marks the Pod busy
until the new agent reports idle, so the Pod is briefly protected rather than
exposed.

What is reset between jobs:

| `runtime` | Reset | Persists |
| --- | --- | --- |
| `standard` | The agent process and its registration, and the contents of `/buildkite/builds` (checkouts) and `/buildkite/plugins`. | The Pod and its node, and the agent container with the rest of its filesystem: `/tmp`, the home directory, packages or tools a job installed, caches outside `/buildkite`, and any processes a job left running. |
| `dind`, `kata`, `sysbox` | The agent container (recreated from the image), every Docker container, network and volume, and the `/buildkite` workspace (checkouts, plugins and sockets). | The Pod and its node, the Docker daemon and its image and build caches, and the Docker client configuration (`DOCKER_CONFIG`, including logins). |

Ephemeral agents keep successive jobs' state apart, but they are not a security
boundary between them. Anything a job can reach that persists, such as files
outside the workspace in a `standard` container or the Pod's Docker image
cache, remains available to later jobs.

### Agent runtime image

Supervised ephemeral `dind`, `kata` and `sysbox` agents can run in a separate
runtime image, including their initial environment/plugin/checkout hooks:

```yaml
defaults:
  ephemeralAgent: true
  runtime: dind
  docker:
    agentRuntimeImage: buildkite/agent-base:ubuntu-noble-hosted-toolchains
```

`image` remains the agent-binary source (`buildkite/agent:4` by default). Docker
mounts its filesystem read-only at `/opt/buildkite-agent-source` inside the
runtime, rather than overlaying it on the runtime's root. Startup copies only
the agent binary to `/buildkite/bin/buildkite-agent` and runs that copy. The
shared path is first on `PATH` and is the agent's `BUILDKITE_BIN_PATH`, so
Docker/Compose plugins and step containers can bind-mount it without
inheriting the source-image mount. No extraction container or custom combined
image is needed, and the existing between-job workspace cleanup is unchanged.

The runtime must match the source binary's architecture and provide `/bin/sh`,
`cp`, a writable workspace and whatever tools/hooks the jobs require.
Source-image configuration and hooks are not copied. With step images enabled
it also needs the Docker CLI and `setsid`. Docker/Compose plugins need their
usual tooling. Without a selected step image, the whole job runs in this
runtime, including initial hooks. A selected explicit/default step image
instead runs the whole job there. If the runtime is already the desired job
image, leave `defaultStepImage` empty to avoid a redundant container. Setting
`docker.stepImages: false` also keeps the whole job in this runtime, but
ignores explicit step images too.

Override `docker.agentRuntimeImage` per pool, or set it to `""` to clear an
inherited runtime. An empty default preserves the existing behavior. Nonempty
values are rejected for persistent agents or `standard` runners rather than
silently ignored.

Requires Docker Engine/CLI 29+ and the containerd image store for `type=image`
mounts. The opt-in explicitly enables that store. For Sysbox this replaces the
usual classic `overlay2` selection. It does not migrate an existing daemon's
images: a runner Pod replacement starts with a fresh emptyDir image cache. The
supervisor refuses an incompatible store instead of falling back to an overlay
or extraction helper. CI exercises isolated Docker image mounts, not Sysbox or
Kata host/runtime compatibility, so validate those before rolling out an
opted-in pool. The feature is not enabled in any deployed values by this chart
change.

Both source and runtime are pulled only when missing, reusing cached mutable
tags between agents, not requesting per-job freshness. Coordinate active jobs
before changing either image or upgrading runner Pods.

### Step images

On `dind`, `kata` and `sysbox` runners, a command step's `image:` runs the
whole job in that image, including plugin and repository checkout. `standard`
runners have no Docker daemon, so they ignore `image:` and run the step in the
agent container.

The agent runs each job through a script from the chart instead of
`buildkite-agent bootstrap`. Set a default whole-job image for steps without a
nonempty `image:`:

```yaml
defaults:
  docker:
    defaultStepImage: buildkite/agent-base:ubuntu-noble-hosted-toolchains
```

An explicit nonempty step `image:` takes precedence. Override
`docker.defaultStepImage` per pool, or set it to `""` there to clear the
default. With neither a step image nor a default, the usual bootstrap runs
unchanged. This does not change `defaults.image`, the agent-binary source. For
either a step image or the configured default, a container started in the Pod's
Docker daemon runs one full `buildkite-agent bootstrap`: plugins, checkout,
hooks and commands. Hook-added, changed and unset environment variables, and
changes to the working directory, stay in the same executor through the command
phase. This does not fix the agent's own environment semantics: agent 4.8 can
reintroduce a hook-unset variable if it was inherited at bootstrap startup,
because its subprocess layer merges the original OS environment back in.
Variables created by an earlier hook and later unset are not affected.

**Upgrading from 0.14:** step images were command-only environments, with
initial plugin/checkout hooks running separately in the agent. They are now
whole-job environments. Supply Git and all initial hook/checkout tools in the
selected image (for example AWS CLI for AWS plugin environment hooks).
Agent-image tools, global hooks, home-directory files and configuration are not
automatically copied into it. Private step images must be pullable using the
existing Docker client configuration before their own hooks can run. A login
performed by a job hook is too late to pull that job's image.

The container mounts the `/buildkite` workspace at the same path, so it sees
the checkout, the plugins, the Job API socket and the agent binary, which the
bootstrap appends to `PATH`. Like the agent, it gets the job's environment,
the Pod's Docker daemon and its Docker client configuration (`DOCKER_CONFIG`).
The image is pulled if the daemon doesn't have it yet, so a tag the daemon
already has isn't updated until the Pod is replaced. The container is removed
when the job finishes and stopped when the job is cancelled. It is named
`buildkite-step-<job ID>` and labeled `buildkite.com/job-id`.

The agent runtime needs the `docker` CLI and `setsid`, which `buildkite/agent`
images have. The step's image must match the agent binary's architecture and
needs Git, `bash` (the default command shell), and any checkout authentication,
SSH/CA or plugin tools the job requires. It must run as a user that can write
to the shared workspace and use the Docker socket when required. No agent
installation is needed in the step image: it runs the shared binary.

An `image:` at the top of a pipeline applies to every step in it, including
steps that use the Docker or Docker Compose plugins. Their hooks then run in
that image, which needs the Docker CLI (and Compose) for them to work. Set
`image:` on the steps that need it instead, or use an image with the Docker
CLI.

To ignore both `image:` and the default and run every step in the agent
container, set `docker.stepImages: false` on an entry. `standard` runners also
ignore the default. Neither explicit nor default images are pulled per job:
the daemon reuses cached tags, including across ephemeral agent replacements.

### Image pull caching

The `dind`, `kata` and `sysbox` Docker daemons can pull images through an
[OCI accelerator](https://github.com/buildkite/oci-accelerator), an HTTPS
proxy that caches registry content on its node's disk. Repeat pulls of
layers and digest-addressed manifests across all runners, and after runners
are replaced, come from the cache. Image names and `docker login` don't change.
Tags and pushes go to the upstream registry, and the registry must approve
access before the proxy serves cached content.

Enable the accelerator:

```yaml
ociAccelerator:
  enabled: true
  registries: [registry-1.docker.io, ghcr.io, public.ecr.aws]
```

Every `dind`, `kata` and `sysbox` entry then uses it. Set
`docker.ociAccelerator: false` on an entry to pull directly.

The proxy signs registry certificates with its own root CA, which it loads from
a Secret in the release namespace. It never generates one itself. Runner Pods
trust only the CA's certificate, which they mount from a separate ConfigMap,
`<release>-buildkite-operator-oci-accelerator-ca-cert`, so only the proxy
references the Secret holding the private key. By default the chart generates
the CA. Before install and every upgrade, a hook Job runs the accelerator's
`init-ca` and stores the result in the Secret
`<release>-buildkite-operator-oci-accelerator-ca`, unless that Secret already
exists, so the CA is created once and then kept. The same Job then copies the
certificate from the Secret into the ConfigMap, creating or updating it, so
upgrading a release installed before the ConfigMap existed creates it. A second
hook Job deletes the ConfigMap and the Secret after `helm uninstall`, but
`helm uninstall --no-hooks` leaves them behind. The hook Jobs run with a
short-lived ServiceAccount that may create Secrets and ConfigMaps, but may
read or delete only that Secret and ConfigMap and update only the ConfigMap,
and Helm itself never renders or stores the private key. To rotate the CA,
delete the Secret, run `helm upgrade`, then restart the proxy StatefulSet and
the runner Deployments.

To manage the CA yourself instead, for example to keep it across reinstalls,
create it once and store it in a Secret in the release namespace. This runs
`init-ca` in a throwaway container and copies the files out:

```bash
mkdir -m 0700 oci-accelerator-ca
docker run --rm --entrypoint /bin/sh buildkite/oci-accelerator:v0.3.0 -ec \
  'mkdir -m 0700 /tmp/state; oci-accelerator init-ca --dir /tmp/state/ca >&2; tar -C /tmp/state/ca -cf - ca.crt ca.key' |
  tar -C oci-accelerator-ca -xf -
kubectl create secret generic oci-accelerator-ca \
  --namespace buildkite-runner-stack \
  --from-file=oci-accelerator-ca/ca.crt \
  --from-file=oci-accelerator-ca/ca.key
```

Keep a secure backup of `ca.key`. Anyone with it can impersonate registries
to the runners' Docker daemons. Then set `ociAccelerator.ca.existingSecret.name:
oci-accelerator-ca`. The chart never creates, changes or deletes a Secret you
name. Its hook Job only reads it, before install and every upgrade, to copy the
certificate into the runners' ConfigMap, so install and upgrade fail until the
Secret exists. After replacing the Secret, run `helm upgrade` to copy the new
certificate, then restart the proxy StatefulSet and the runner Deployments.

The chart installs:

- A StatefulSet running `ociAccelerator.replicas` proxies (default 1), and a
  ClusterIP Service that the Docker daemons use as their HTTPS proxy.
- A headless Service providing stable per-Pod DNS names for the StatefulSet,
  also used for discovery when peering is enabled.
- A NetworkPolicy admitting only this release's runner Pods
  (`networkPolicy.enabled`). Enforcement requires a network plugin that
  supports NetworkPolicy.

Each daemon sends all of its HTTPS traffic through the proxy. Only
`registries` are cached. Other hosts are tunneled through it unchanged. List
hosts the proxy cannot reach, such as in-cluster registries, in `noProxy`.
Pulls fail while the proxy is unavailable. Job containers don't inherit the
daemon's proxy settings.

Multiple replicas work with or without peering. Without peering, each proxy
fills its cache independently from origin, even if another proxy has the
content. The Service distributes connections, not individual image layers,
so long-lived connections can keep using the same replica. Proxies prefer
spreading across nodes without requiring a separate node for each replica.
Cache size and resource requests apply **per replica**.

Use at least two replicas to keep a proxy available during StatefulSet rolling
updates, which replace one Pod at a time without surging. A single replica has
an availability gap during updates or node replacement. In-flight pulls through
a terminating proxy can still fail, even with multiple replicas.

**Upgrading from 0.16:** the accelerator changes from a Deployment to a
StatefulSet, discarding the old workload's cache and potentially interrupting
pulls. Schedule this one-time transition outside active builds. The proxy
Service and CA stay the same, so runners need no configuration change or
restart.

#### Peering

For multiple proxies that can fetch cached content from one another, enable
peering and set the replica count:

```yaml
ociAccelerator:
  enabled: true
  replicas: 3
  peering:
    enabled: true
```

Runners keep using the same proxy Service on port 3128. The StatefulSet's
headless Service also exposes port 7443. The chart seeds each proxy with all the
replicas' names, including its own, which the accelerator ignores. Seeds are
DNS names, not snapshots of Pod IPs, so replacements can rediscover each other.
Pods start in parallel, and peer DNS is published before readiness. No API
access or discovery sidecar is needed.

Peers use mutual TLS with the release's existing CA and private key. The
NetworkPolicy allows port 7443 only between this release's accelerator Pods,
and runner access stays limited to port 3128. Keep the existing CA-key
placement precautions below for every proxy node.

Each replica has its own `emptyDir` cache and peer state. Both survive container
restarts, but Pod replacement loses its cache and creates a new peer identity.
Peering is not sharding or proactive replication: popular content can be
duplicated across caches, and losing every proxy Pod loses all cached content.
A peer miss or unavailable peer falls back to origin. The requesting proxy
still obtains upstream registry authorization before fetching peer content.
Mutable tag responses are not shared.

With peering enabled, changing the replica count changes the seed list and
rolls the fleet. Discovery and cache inventory refresh are asynchronous, so a
new proxy can initially fetch from origin before peer hints are available.

Switching peering on or off rolls the existing StatefulSet, replacing each
Pod's cache and peer identity without changing workload kind, governing Service,
runner endpoint or CA. Runner Pods need no configuration change or restart.
The 40-second Pod termination grace covers the default proxy and peer drains.
Keep any `OCI_ACCELERATOR_SHUTDOWN_TIMEOUT` override below half that budget,
leaving time for cleanup.

#### Cache storage and trust

Besides content addressed by digest, the proxy keeps tag manifests, tag lists,
referrer lists and catalog responses in memory for 30 seconds. A tag pushed or
moved during that time can still resolve to its previous digest, for example
when one step pushes `myapp:latest` and the next pulls it. Set
`OCI_ACCELERATOR_CACHE_MUTABLE_TTL: "0s"` in `extraEnv` to disable this.

The cache is an `emptyDir` on the proxy's node, limited to `cache.size`
(default 20Gi), so it needs no StorageClass. It outlives runner Pods but starts
empty whenever the proxy Pod is replaced: on upgrades that change it and when
its node is removed. Container restarts within a Pod keep the cache. The proxy
requests `cache.size` of `ephemeral-storage`, unless `resources.requests` sets
it, so it is only scheduled on a node with that much disk free. Runner Pods
with a Docker daemon request disk too, so size it to fit beside them, or place
the proxy with `nodeSelector` and `tolerations`. Keep `cache.maxBytes` below
`cache.size`.

The daemons trust the CA for every host, not only `registries`. Docker Engine
does not read `/etc/docker/certs.d` for Docker Hub with the classic image
store used by `sysbox`, so per-registry trust is not possible. Runner Pods
reference only the certificate's ConfigMap, never the CA Secret. This matters
because a node's kubelet can read every key of any Secret that a Pod on the
node references, whatever `items` the Pod mounts, so a job that escapes to its
node can read those Secrets. The private key is mounted only in the proxy, and
held briefly by the hook Job that generates or copies it. Pods read the CA at
startup, so after replacing it restart the proxy StatefulSet and the runner
Deployments. Other `OCI_ACCELERATOR_*` settings can be passed through
`ociAccelerator.extraEnv`. See the accelerator's
[deployment guide](https://github.com/buildkite/oci-accelerator/blob/main/docs/deployment.md#configuration).

The proxy's node holds the CA private key that every accelerated daemon
trusts, including those of `kata` and `sysbox` pools running untrusted jobs.
A `dind` job can escape to its node and read the Secrets mounted in other Pods
there, so a release with `dind` pools should keep the proxy off nodes `dind`
runners can reach. The chart adds no node selector for `dind`, so place the
proxy with `ociAccelerator.nodeSelector` and `tolerations`, for example on
nodes tainted for `kata` or `sysbox`, or on dedicated system nodes. The hook
Jobs that generate, copy and delete the CA use the same placement. Without the
deletion-cost admission policy, such a job could instead use a runner's token
to change the proxy Pod's image. See
[Scale-in preference](#scale-in-preference).

### Registry credentials

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

The values file must provide the runner pools and agent token Secret
references described in [Quickstart](#quickstart), and KEDA must already be
installed. Any private container images used by your configuration still need
their own pull credentials. For digest-pinned installs, replace the chart URL
with the `oci://…@sha256:…` reference from the release log and omit `--version`.

Run `python3 hack/test_publish_chart.py` to test release handling locally. It
uses real Helm chart packaging with simulated registry and credential services.
It does not retrieve secrets or publish to Docker Hub.

## License

MIT — see [LICENSE](LICENSE).
