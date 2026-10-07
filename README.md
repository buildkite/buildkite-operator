# buildkite-operator

This repository includes a standalone Helm chart for autoscaling Buildkite
runners on Kubernetes. One release can serve several Buildkite queues; each gets
its own runner pool (a `Deployment` of agent Pods) and KEDA scaling, sharing one
token Secret.

## Prerequisite

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

KEDA must be configured to watch the namespace where the runner chart is
installed. The chart validates that the `ScaledObject` and
`TriggerAuthentication` APIs are discoverable and otherwise fails with a KEDA
prerequisite error. API discovery cannot confirm that KEDA's controller is
healthy, that its namespace watch configuration includes the release namespace,
or which KEDA version serves those APIs.

## Quickstart

Add an entry under `queues` for each Buildkite queue, with its maximum runner
count, and provide the cluster agent token. The entry name (`linux` below) is
used in resource names:

```bash
export BUILDKITE_AGENT_TOKEN='<agent-token>'

helm upgrade --install buildkite-operator ./charts/buildkite-operator \
  --namespace buildkite-operator-system \
  --create-namespace \
  --set-string queues.linux.queue=<queue> \
  --set queues.linux.maxReplicas=<maximum> \
  --set-string agentToken.value="$BUILDKITE_AGENT_TOKEN"
```

Helm stores supplied values in its release data. For production secret
management, create the Secrets separately in the release namespace and
reference them instead:

```bash
helm upgrade --install buildkite-operator ./charts/buildkite-operator \
  --namespace buildkite-operator-system \
  --create-namespace \
  --set-string queues.linux.queue=<queue> \
  --set queues.linux.maxReplicas=<maximum> \
  --set-string agentToken.existingSecret.name=<agent-secret> \
  --set-string metricsToken.existingSecret.name=<metrics-secret>
```

The metrics Secret key must contain the complete `Authorization` value in the
form `Token <cluster-agent-token>`.

## Queues

Each entry under `queues` serves one Buildkite queue and inherits every setting
from `defaults`, overriding any of them. For example, a values file serving a
Kata queue and a Sysbox queue with ephemeral agents:

```yaml
defaults:
  minReplicas: 1

queues:
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

Every entry needs `queue` and `maxReplicas`. Entry names are lowercase letters,
digits and hyphens. Each Buildkite queue may appear in only one entry, because
KEDA scales an entry on its queue's whole job count. Because `queues` is a map,
a later values file can change one entry (`linux-kata: {maxReplicas: 25}`) or
remove it (`build-sysbox: null`) without restating the others. With no
entries, the chart installs nothing.

Each entry gets a runner pool: a `Deployment` whose Pods are labelled
`buildkite.com/runner-pool: <entry>`, and a `ScaledObject` that scales it, both
named `<release>-<entry>`. The token Secret, KEDA `TriggerAuthentication`, and
deletion-cost permissions and scripts are shared by all entries in a release.
Queues in a different Buildkite cluster need a different token, so they use a
separate release.

| Setting | Default | Description |
| --- | --- | --- |
| `queue` | required | Buildkite queue key the agents serve and scale on. |
| `maxReplicas` | required | Upper bound on runners. |
| `minReplicas` | `1` | Runners kept when the queue is idle. |
| `runtime` | `standard` | `standard`, `dind`, `kata` or `sysbox`; see [Runner isolation](#runner-isolation). |
| `ephemeralAgent` | `false` | Replace the agent after every job, with a clean workspace. The Pod persists. See [Ephemeral agents](#ephemeral-agents). |
| `terminationGracePeriodSeconds` | `3600` | Longest time an agent may take to drain its job. |
| `pollingInterval`, `cooldownPeriod` | `10`, `60` | KEDA polling interval, and how long the queue must be fully idle before KEDA scales an entry with `minReplicas: 0` to zero, in seconds. KEDA removes every remaining runner at once, without waiting for `scaleDownStabilizationWindowSeconds`. To keep an idle pool longer, raise `cooldownPeriod`. |
| `scaleDownStabilizationWindowSeconds` | `60` | Seconds the HPA waits before removing runners after the job count drops (0–3600), while at least one runner is still needed. Covers dips between dependent steps. |
| `image`, `resources` | `buildkite/agent:4` | Agent image, and requests and limits for the agent container. With `dind`, `kata` or `sysbox` and `ephemeralAgent`, `resources` is ignored: agents run as containers inside the Docker daemon and share its `docker.resources` budget. With `standard` and `ephemeralAgent`, the image also needs `/bin/sh`. |
| `docker` | `docker:29.7.2-dind` | Docker daemon image, resources and storage for `dind`, `kata` and `sysbox`. With `ephemeralAgent`, `docker.resources` also bounds the agent containers. `docker.ociAccelerator` (default `true`) pulls through the [OCI accelerator](#image-pull-caching) when it is enabled. |

### Examples

Ephemeral standard agents. Every job gets a fresh agent and an empty workspace
in a plain Pod with no Docker daemon. The container keeps running, so files
outside the workspace carry over between jobs:

```yaml
queues:
  linux:
    queue: linux
    ephemeralAgent: true
    maxReplicas: 10
```

Persistent Sysbox agents. Each Pod runs one long-lived agent next to an
unprivileged Docker daemon, so containers, volumes, checkouts and caches carry
over between jobs. The pool scales to zero when the queue is idle:

```yaml
queues:
  docker-builds:
    queue: docker-builds
    runtime: sysbox
    minReplicas: 0
    maxReplicas: 4
```

Persistent Docker-in-Docker agents, for trusted jobs on clusters that can't
run Kata or Sysbox. Each Pod runs one long-lived agent next to a privileged
Docker daemon, on any node; see [Privileged Docker-in-Docker](#privileged-docker-in-docker)
before using it:

```yaml
queues:
  docker:
    queue: docker
    runtime: dind
    maxReplicas: 4
```

Ephemeral Kata agents. Each job runs in a fresh agent container inside a
VM-isolated Pod. Afterwards its containers, networks, volumes and workspace are
removed, while Docker's image and build caches are kept:

```yaml
queues:
  untrusted:
    queue: untrusted
    runtime: kata
    ephemeralAgent: true
    maxReplicas: 6
```

To turn a pool off, comment out or delete its entry, or set it to `null` in a
later values file, for example `helm upgrade ... -f values.yaml -f off.yaml`
with:

```yaml
# off.yaml
queues:
  untrusted: null
```

Helm then removes the pool's `Deployment` and `ScaledObject`, and its agents
drain their current jobs. `maxReplicas` must be at least 1; to keep a pool
without idle runners, set `minReplicas: 0` instead.

## Autoscaling

KEDA polls Buildkite's Agent Metrics API. For each queue entry it scales for
`scheduled + running` jobs, keeps one runner warm by default, and scales up to
the entry's `maxReplicas`. While jobs are scheduled or running, the HPA
removes runners only after the lower count has persisted for
`scaleDownStabilizationWindowSeconds`, because jobs blocked on `depends_on` are
not counted until their dependencies finish. Once the queue has no scheduled or
running jobs, an entry with `minReplicas: 0` scales to zero after
`cooldownPeriod` instead.

KEDA's HPA chooses scale-in victims without confirming that a selected agent is
idle. The agent drains a running job on its first SIGTERM, bounded by
`terminationGracePeriodSeconds`. The configured maximum bounds desired
replicas, but terminating Pods may briefly overlap replacement capacity. KEDA
remains installed when a runner chart release is uninstalled and can be shared
by multiple runner releases in the cluster.

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
pinned by digest. The sidecar receives the only Kubernetes API token in the Pod,
but because Deployment Pod names are generated, its Role can patch every Pod in
the release namespace. Install the chart in a namespace dedicated to runners.

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

Set `runtime` in `defaults` or on a queue entry to choose its isolation profile:

| Value | Runner Pod |
| --- | --- |
| `standard` (default) | A Buildkite agent in a regular Kubernetes Pod, with no Docker daemon. |
| `dind` | An agent and privileged Docker native sidecar in a regular Pod on any node. Not isolation; see [Privileged Docker-in-Docker](#privileged-docker-in-docker). |
| `kata` | An agent and privileged Docker native sidecar inside the `kata-qemu-runtime-rs` VM RuntimeClass. |
| `sysbox` | An agent and unprivileged Docker native sidecar using the `sysbox-runc` RuntimeClass and Kubernetes user namespaces. |

Different entries in one release can use different profiles. `standard` and
`dind` need nothing installed. Kata and Sysbox are host runtimes, so the chart
deliberately does not install them or modify containerd. Like KEDA, they are cluster-wide installs, done
once per cluster before installing the chart:

| `runtime` | RuntimeClass | Installer | Nodes |
| --- | --- | --- | --- |
| `kata` | `kata-qemu-runtime-rs` | [kata-deploy](https://github.com/kata-containers/kata-containers/tree/main/tools/packaging/kata-deploy) | KVM-capable, labelled and tainted (`NoSchedule`) `experiments.buildkite.com/runtime=kata` |
| `sysbox` | `sysbox-runc` | [sysbox-deploy-k8s](https://github.com/nestybox/sysbox/blob/master/docs/user-guide/install-k8s.md) | Kubernetes user namespaces support, labelled and tainted (`NoSchedule`) `experiments.buildkite.com/runtime=sysbox` |

Each installer must target the runtime's nodes and tolerate their
`experiments.buildkite.com/runtime=<kata|sysbox>:NoSchedule` taint; neither
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
The tolerations list replaces upstream's, so keep its `sysbox-runtime=not-running`
toleration:

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

The `dind`, `kata` and `sysbox` profiles require Kubernetes native sidecars;
Sysbox additionally requires Kubernetes user namespaces. Their Docker data and
workspace are Pod-local and are discarded when an agent Pod is removed.

### Privileged Docker-in-Docker

`runtime: dind` is for clusters that can't run Kata or Sysbox but whose jobs
need Docker. The Pod runs the same Docker daemon sidecar as `kata` and
`sysbox`, privileged and without a RuntimeClass, so it schedules on any node.

> [!WARNING]
> A privileged container has host-level access to its node: it can see host
> devices, load kernel modules and escape to the host. `dind` is not isolation.
> Only run trusted jobs on `dind` queues, and don't share their nodes with
> workloads those jobs must not reach.

The namespace must allow privileged Pods. With Pod Security Admission, label it
for the `privileged` level, for example
`kubectl label namespace <namespace> pod-security.kubernetes.io/enforce=privileged`.
`kata` runners need the same, because their Docker daemon is privileged inside
the VM. The chart adds no node selector or toleration for `dind`, so its Pods
can land on any node; dedicated nodes for `dind` runners aren't configurable
yet.

### Ephemeral agents

`ephemeralAgent` controls the Buildkite agent, not the Pod. Runner Pods always
persist across jobs; only autoscaling adds or removes them.

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
| `dind`, `kata`, `sysbox` | The agent container (recreated from the image), every Docker container, network and volume, and the `/buildkite` workspace (checkouts, plugins and sockets). | The Pod and its node, the Docker daemon and its image and build caches. |

Ephemeral agents keep successive jobs' state apart; they are not a security
boundary between them. Anything a job can reach that persists, such as files
outside the workspace in a `standard` container or the Pod's Docker image
cache, remains available to later jobs.

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

Every `dind`, `kata` and `sysbox` entry then uses it. Set `docker.ociAccelerator: false`
on an entry to pull directly.

The proxy signs registry certificates with its own root CA, which it loads from
a Secret in the release namespace; it never generates one itself. By default
the chart generates the CA. Before install and every upgrade, a hook Job runs
the accelerator's `init-ca` and stores the result in the Secret
`<release>-buildkite-operator-oci-accelerator-ca`, unless that Secret already
exists, so the CA is created once and then kept. A second hook Job deletes the
Secret after `helm uninstall`; `helm uninstall --no-hooks` leaves it behind.
The hook Jobs run with a short-lived ServiceAccount that may create Secrets
and read or delete only that one, and Helm itself never renders or stores the
private key. To rotate the CA, delete the Secret, run `helm upgrade`, then
restart the proxy Deployment and the runner Deployments.

To manage the CA yourself instead, for example to keep it across reinstalls,
create it once and store it in a Secret in the release namespace. This runs
`init-ca` in a throwaway container and copies the files out:

```bash
mkdir -m 0700 oci-accelerator-ca
docker run --rm --entrypoint /bin/sh buildkite/oci-accelerator:v0.2.1 -ec \
  'mkdir -m 0700 /tmp/state; oci-accelerator init-ca --dir /tmp/state/ca >&2; tar -C /tmp/state/ca -cf - ca.crt ca.key' |
  tar -C oci-accelerator-ca -xf -
kubectl create secret generic oci-accelerator-ca \
  --namespace buildkite-operator-system \
  --from-file=oci-accelerator-ca/ca.crt \
  --from-file=oci-accelerator-ca/ca.key
```

Keep a secure backup of `ca.key`. Anyone with it can impersonate registries
to the runners' Docker daemons. Then set `ociAccelerator.ca.existingSecret.name:
oci-accelerator-ca`. The chart never creates, changes or deletes a Secret you
name; until it exists, the proxy and runner Pods don't start.

The chart installs:

- A single-replica Deployment running the proxy, and a Service that the Docker
  daemons use as their HTTPS proxy.
- A NetworkPolicy admitting only this release's runner Pods
  (`networkPolicy.enabled`). Enforcement requires a network plugin that
  supports NetworkPolicy.

Each daemon sends all of its HTTPS traffic through the proxy. Only
`registries` are cached; other hosts are tunnelled through it unchanged. List
hosts the proxy cannot reach, such as in-cluster registries, in `noProxy`.
Pulls fail while the proxy is unavailable. Upgrades start the new proxy before
stopping the old one, but pulls fail if its node is lost until a replacement
starts. Job containers don't inherit the daemon's proxy settings.

The cache is an `emptyDir` on the proxy's node, limited to `cache.size`
(default 20Gi), so it needs no StorageClass. It outlives runner Pods but starts
empty whenever the proxy Pod is replaced: on upgrades that change it, on
restarts, and when its node is removed. The proxy requests `cache.size` of
`ephemeral-storage`, unless `resources.requests` sets it, so it is only
scheduled on a node with that much disk free. Runner Pods with a Docker daemon
request disk too, so size it to fit beside them, or place the proxy with
`nodeSelector` and `tolerations`. Keep `cache.maxBytes` below `cache.size`.

The daemons trust the CA for every host, not only `registries`. Docker Engine
does not read `/etc/docker/certs.d` for Docker Hub with the classic image
store used by `sysbox`, so per-registry trust is not possible. Runner Pods are
given only the certificate; the private key is mounted only in the proxy and,
briefly, the hook Job that generates it.
Pods read the Secret at startup, so after replacing the CA restart the
proxy Deployment and the runner Deployments. Other `OCI_ACCELERATOR_*` settings can
be passed through `ociAccelerator.extraEnv`; see the accelerator's
[deployment guide](https://github.com/buildkite/oci-accelerator/blob/main/docs/deployment.md#configuration).

The proxy's node holds the CA private key that every accelerated daemon
trusts, including those of `kata` and `sysbox` queues running untrusted jobs.
A `dind` job can escape to its node and read the Secrets mounted in other Pods
there, so a release with `dind` queues should keep the proxy off nodes `dind`
runners can reach. The chart adds no node selector for `dind`, so place the
proxy with `ociAccelerator.nodeSelector` and `tolerations`, for example on
nodes tainted for `kata` or `sysbox`, or on dedicated system nodes. The hook
Jobs that generate and delete the CA use the same placement.

## Development

```bash
make test-helm        # lint and render the standalone chart
make helm-examples    # update the chart's rendered examples
make test-supervisor  # run the ephemeral-agent supervisor against Docker
make test-helm-e2e    # install and uninstall the chart in isolated Kind
make lint             # golangci-lint
make test             # Go tests and generated-file checks
make install-hooks    # use the Git hooks in .githooks
```

Each directory under `charts/buildkite-operator/examples` pairs a
`values.yaml` with the `rendered.yaml` that `helm template` produces from it,
so chart changes show up as manifest diffs in review. The pre-commit hook
installed by `make install-hooks` renders the staged chart and stops the commit
if the staged examples don't match. Unstaged changes are ignored.

CI runs the checks, and also fails if the rendered examples are out of date.
The end-to-end check deletes its isolated Kind cluster when it finishes, which
may clear the current kubeconfig context.

## License

MIT — see [LICENSE](LICENSE).
