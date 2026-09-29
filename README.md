# buildkite-operator

A Kubernetes operator for Buildkite runners.

Declare a pool of Buildkite agents as a Kubernetes resource, and the operator
keeps a warm buffer of idle agent Pods against the queue you name:

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
  agentTokenSecretRef:
    name: buildkite-agent-token
    key: token
```

```console
$ kubectl get runnerpools
NAME             MAX   IDLE   BUSY   TOTAL   AGE
linux-builders   20    3      7      10      2m
```

> **Status: early.** The API is `v1alpha1` and will change. The operator does not
> query Buildkite queue depth. It polls each agent's local status endpoint and
> passes your agent token through by secret reference.

## Quickstart

The standalone chart installs a Buildkite agent `Deployment`, KEDA, its
`ScaledObject`, and the required token Secret. It does not use the custom
`RunnerPool` API or install this repository's operator. Provide the Buildkite
queue, maximum runner count, and cluster agent token:

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
management, create the Secret separately in the release namespace and reference
it instead:

```bash
helm upgrade --install buildkite-operator ./charts/buildkite-operator \
  --namespace buildkite-operator-system \
  --create-namespace \
  --set-string runners.queue=<queue> \
  --set runners.maxReplicas=<maximum> \
  --set-string agentToken.existingSecret.name=<agent-secret> \
  --set-string metricsToken.existingSecret.name=<metrics-secret>
```

KEDA is vendored into the chart and polls Buildkite's Agent Metrics API. It
scales for `scheduled + running` jobs, keeps one runner warm by default, and
scales up to `runners.maxReplicas`. Set `keda.enabled=false` only when a
compatible KEDA installation already watches the release namespace. With
existing Secrets, the metrics Secret key must contain the complete
`Authorization` value (`Token <cluster-agent-token>`).

KEDA's HPA chooses scale-in victims; unlike `RunnerPool`, it does not confirm
that a selected agent is idle. The agent drains a running job on its first
SIGTERM, bounded by `runners.terminationGracePeriodSeconds`. The configured
maximum bounds desired replicas, but terminating Pods may briefly overlap
replacement capacity. KEDA CRDs are retained when the release is uninstalled.

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

To run the operator directly during development instead:

```bash
make install && make run
kubectl apply -f config/samples/v1alpha1_runnerpool.yaml
```

## RunnerPool

| Field | Required | Default | Description |
| --- | --- | --- | --- |
| `spec.queue` | yes | — | The Buildkite queue agents register with, passed to agents as `BUILDKITE_AGENT_TAGS=queue=<queue>`. |
| `spec.maxRunners` | yes | — | Hard cap on the total number of agent Pods. Must be at least `1`. |
| `spec.minIdleRunners` | no | `1` | Number of confirmed-idle agents to keep warm. Must not exceed `maxRunners`. |
| `spec.idleTimeoutSeconds` | no | `10` | How long an agent must be observed idle before surplus capacity is removed. |
| `spec.terminationGracePeriodSeconds` | no | `3600` | Time Kubernetes allows an agent to finish a job after SIGTERM before forcefully stopping it. |
| `spec.image` | no | `buildkite/agent:3` | Agent image. It must provide the Buildkite agent health server and graceful SIGTERM behavior; Buildkite agent v3.72.0 or newer is required. |
| `spec.runtime` | no | `standard` | Pod isolation profile: `standard`, `kata`, or `sysbox`. Kata and Sysbox require compatible nodes and a pre-installed RuntimeClass. |
| `spec.agentTokenSecretRef` | yes | — | Secret name and key holding the Buildkite agent token, exposed to agents as `BUILDKITE_AGENT_TOKEN`. |
| `spec.resources` | no | — | Compute resources for each agent container. |

The operator polls each Pod's `/status.json`. A busy agent causes another warm
agent to be created, up to `maxRunners`. A confirmed-idle surplus is removed
after `idleTimeoutSeconds`; warming or unreachable Pods count toward the total
but are never treated as idle scale-down candidates. Each eviction is rechecked
immediately before deletion, and the agent's first SIGTERM drains any job that
raced with that check. A Pod being deleted keeps counting toward `maxRunners`
until Kubernetes finishes removing it, so a draining agent cannot be replaced
early and briefly push the pool over its hard cap.

`minIdleRunners: 0` allows scale-to-zero. Because this operator deliberately
does not query queue depth, a pool at zero remains dormant until
`minIdleRunners` is increased. Idle duration is observational: a short job
entirely between polls may not reset the timer, but graceful termination still
prevents that job from being lost.

Status reports `totalRunners`, `idleRunners`, `busyRunners`, `readyRunners`,
`observedGeneration`, and a `Ready` condition. `idleRunners` includes only
Kubernetes-ready Pods confirmed idle; unreachable and warming Pods are the
difference between the total and the confirmed busy/idle counts:

```bash
kubectl describe runnerpool linux-builders
```

Each pool directly owns Pods named `<pool>-agent-*`, labelled
`buildkite.com/runner-pool=<pool>`. Changes to the queue, image, token reference,
resources, or termination grace period roll through idle Pods without
interrupting busy agents. `maxRunners` remains a hard cap, so a replacement at
the cap can briefly reduce the warm buffer by one. Deleting the pool gracefully
terminates all of its Pods through owner-reference garbage collection.

This version replaces the earlier Deployment-based `v1alpha1` implementation
without an in-place migration. Delete and recreate existing RunnerPools when
upgrading so their legacy Deployments do not continue running alongside the new
directly managed Pods.

## Development

```bash
make test           # unit tests against envtest
make test-helm      # lint and render the standalone chart
make test-helm-e2e  # install and uninstall the chart in isolated Kind
make lint           # golangci-lint
make build          # regenerate manifests and build the manager binary
```

CI runs `lint`, codegen/chart drift checks, `test`, and `test-helm-e2e` — see
[.buildkite/pipeline.yml](.buildkite/pipeline.yml). The drift check fails if
generated CRDs, RBAC or deepcopy code are stale, so run `make manifests generate`
after touching [api/v1alpha1/runnerpool_types.go](api/v1alpha1/runnerpool_types.go)
or the `+kubebuilder:rbac` markers in
[internal/controller/runnerpool_controller.go](internal/controller/runnerpool_controller.go).

The standalone chart in `charts/buildkite-operator` is maintained independently
from Kubebuilder manifests. Run its chart checks after changing it:

```bash
make test-helm
```

Note that `make test-helm-e2e` deletes its kind cluster when it finishes, which
also clears your kubeconfig's current context. Run
`kubectl config use-context ...` to point back at your own cluster.

## License

MIT — see [LICENSE](LICENSE).
