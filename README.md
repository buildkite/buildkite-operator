# buildkite-operator

This repository includes a standalone Helm chart for autoscaling Buildkite
runners on Kubernetes. The chart installs a Buildkite agent `Deployment`, KEDA
scaling resources, and the required token Secret.

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

Provide the Buildkite queue, maximum runner count, and cluster agent token:

```bash
export BUILDKITE_AGENT_TOKEN='<agent-token>'

helm upgrade --install buildkite-operator ./charts/buildkite-operator \
  --namespace buildkite-operator-system \
  --create-namespace \
  --set-string runners.queue=<queue> \
  --set runners.maxReplicas=<maximum> \
  --set-string agentToken.value="$BUILDKITE_AGENT_TOKEN"
```

Helm stores supplied values in its release data. For production secret
management, create the Secrets separately in the release namespace and
reference them instead:

```bash
helm upgrade --install buildkite-operator ./charts/buildkite-operator \
  --namespace buildkite-operator-system \
  --create-namespace \
  --set-string runners.queue=<queue> \
  --set runners.maxReplicas=<maximum> \
  --set-string agentToken.existingSecret.name=<agent-secret> \
  --set-string metricsToken.existingSecret.name=<metrics-secret>
```

The metrics Secret key must contain the complete `Authorization` value in the
form `Token <cluster-agent-token>`.

## Autoscaling

KEDA polls Buildkite's Agent Metrics API. It scales for `scheduled + running`
jobs, keeps one runner warm by default, and scales up to
`runners.maxReplicas`.

KEDA's HPA chooses scale-in victims without confirming that a selected agent is
idle. The agent drains a running job on its first SIGTERM, bounded by
`runners.terminationGracePeriodSeconds`. The configured maximum bounds desired
replicas, but terminating Pods may briefly overlap replacement capacity. KEDA
remains installed when a runner chart release is uninstalled and can be shared
by multiple runner releases in the cluster.

### Scale-in preference

Each runner Pod includes a small sidecar that polls the agent's
local `/status.json` endpoint every second. Busy or unknown agents get
`controller.kubernetes.io/pod-deletion-cost: "100"`; idle agents have the
annotation removed, so the ReplicaSet prefers removing idle agents.

This is best-effort. Kubernetes can still select a busy Pod, and deletion cost
does not protect against node drains or evictions. The sidecar is always enabled
because it is part of the chart's autoscaling behavior, and its Python image is
pinned by digest. The sidecar receives the only Kubernetes API token in the Pod,
but because Deployment Pod names are generated, its Role can patch every Pod in
the release namespace. Install the chart in a namespace dedicated to runners.

## Runner isolation

Set `runners.runtime` to choose the runner isolation profile:

| Value | Runner Pod |
| --- | --- |
| `standard` (default) | A Buildkite agent in a regular Kubernetes Pod. |
| `kata` | An agent and privileged Docker native sidecar inside the `kata-qemu-runtime-rs` VM RuntimeClass. |
| `sysbox` | An agent and unprivileged Docker native sidecar using the `sysbox-runc` RuntimeClass and Kubernetes user namespaces. |

For example, add `--set-string runners.runtime=kata` to the Helm command.
Kata and Sysbox are host runtimes, so the chart deliberately does not install
them or modify containerd. Before installing the chart, prepare dedicated nodes
labelled and tainted with `experiments.buildkite.com/runtime=kata` or
`experiments.buildkite.com/runtime=sysbox`, and install the matching RuntimeClass.
Both profiles require Kubernetes native sidecars; Sysbox additionally requires
Kubernetes user namespaces. Their Docker data and workspace are Pod-local and
are discarded when an agent Pod is removed.

### Single-use job containers

By default an agent container serves many jobs, so files, containers and
volumes from one job remain for the next. With `kata` or `sysbox`, set
`runners.singleUse=true` to run each job in a fresh agent container:

```bash
--set-string runners.runtime=sysbox --set runners.singleUse=true
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
