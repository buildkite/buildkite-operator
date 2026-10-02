# buildkite-operator

This repository includes a standalone Helm chart for autoscaling Buildkite
runners on Kubernetes. One release can serve several Buildkite queues; each gets
its own agent `Deployment` and KEDA scaling, sharing one token Secret.

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
Kata queue and a single-use Sysbox queue:

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
    singleUse: true
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

Each entry gets a `Deployment` and `ScaledObject` named `<release>-<entry>`.
The token Secret, KEDA `TriggerAuthentication`, and deletion-cost permissions
and scripts are shared by all entries in a release. Queues in a different
Buildkite cluster need a different token, so they use a separate release.

| Setting | Default | Description |
| --- | --- | --- |
| `queue` | required | Buildkite queue key the agents serve and scale on. |
| `maxReplicas` | required | Upper bound on runners. |
| `minReplicas` | `1` | Runners kept when the queue is idle. |
| `runtime` | `standard` | `standard`, `kata` or `sysbox`; see [Runner isolation](#runner-isolation). |
| `singleUse` | `false` | Run each job in a fresh agent container; see [Single-use job containers](#single-use-job-containers). |
| `terminationGracePeriodSeconds` | `3600` | Longest time an agent may take to drain its job. |
| `pollingInterval`, `cooldownPeriod` | `10`, `60` | KEDA polling interval, and how long the queue must be fully idle before KEDA scales an entry with `minReplicas: 0` to zero, in seconds. KEDA removes every remaining runner at once, without waiting for `scaleDownStabilizationWindowSeconds`. To keep an idle pool longer, raise `cooldownPeriod`. |
| `scaleDownStabilizationWindowSeconds` | `60` | Seconds the HPA waits before removing runners after the job count drops (0–3600), while at least one runner is still needed. Covers dips between dependent steps. |
| `image`, `resources` | `buildkite/agent:4` | Agent image, and requests and limits for the long-lived agent container. With `singleUse`, `resources` is ignored: job containers run inside the Docker daemon and share its `docker.resources` budget. |
| `docker` | `docker:29.7.2-dind` | Docker daemon image, resources and storage for `kata` and `sysbox`. With `singleUse`, `docker.resources` also bounds the job containers. |

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
`kata` and `sysbox` runners use disk-backed `emptyDir` volumes for Docker data
and the workspace, and Cluster Autoscaler's default
`--skip-nodes-with-local-storage=true` would otherwise never remove their
nodes. This is also best-effort: an agent that accepts a job after Cluster
Autoscaler checks its node but before eviction is still bounded by
`--max-graceful-termination-sec`. Node drains outside Cluster Autoscaler,
such as `kubectl drain` or spot interruptions, ignore the annotation.

## Runner isolation

Set `runtime` in `defaults` or on a queue entry to choose its isolation profile:

| Value | Runner Pod |
| --- | --- |
| `standard` (default) | A Buildkite agent in a regular Kubernetes Pod. |
| `kata` | An agent and privileged Docker native sidecar inside the `kata-qemu-runtime-rs` VM RuntimeClass. |
| `sysbox` | An agent and unprivileged Docker native sidecar using the `sysbox-runc` RuntimeClass and Kubernetes user namespaces. |

Different entries in one release can use different profiles.
Kata and Sysbox are host runtimes, so the chart deliberately does not install
them or modify containerd. Like KEDA, they are cluster-wide installs, done
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

Both profiles require Kubernetes native sidecars; Sysbox additionally requires
Kubernetes user namespaces. Their Docker data and workspace are Pod-local and
are discarded when an agent Pod is removed.

### Single-use job containers

By default an agent container serves many jobs, so files, containers and
volumes from one job remain for the next. With `kata` or `sysbox`, set
`singleUse: true` on a queue entry to run each job in a fresh agent container:

```yaml
queues:
  build-sysbox:
    queue: build
    runtime: sysbox
    singleUse: true
    maxReplicas: 4
```

A supervisor container then starts the agent inside the Pod's Docker daemon
with `--disconnect-after-job`. After each job it removes the job's
containers, networks and volumes, clears the workspace, and starts a new agent
under a new name. The Pod, its node, and Docker's image and build caches
persist. If cleanup fails, no new agent starts until it succeeds.

This separates successive jobs' files and containers; it is not a security
boundary between them. Anything a job can reach through the Pod's Docker
daemon, including the cached images, remains available to later jobs. The
`standard` profile has no Docker daemon, so the chart rejects `singleUse` with
it.

## Development

```bash
make test-helm        # lint and render the standalone chart
make test-supervisor  # run the single-use supervisor against Docker
make test-helm-e2e    # install and uninstall the chart in isolated Kind
make lint             # golangci-lint
make test             # Go tests and generated-file checks
```

CI runs all five checks. The end-to-end check deletes its isolated Kind cluster
when it finishes, which may clear the current kubeconfig context.

## License

MIT — see [LICENSE](LICENSE).
