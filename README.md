# buildkite-operator

A Kubernetes operator for Buildkite runners.

Declare a pool of Buildkite agents as a Kubernetes resource, and the operator
keeps a warm buffer of idle agent Pods against the queue you name. Pools can
optionally share an operator-managed, Garage-backed S3 cache:

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
  image: buildkite/agent:3.128.0
  agentTokenSecretRef:
    name: buildkite-agent-token
    key: token
  cacheStoreRef:
    name: build-cache
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

Requires a Kubernetes cluster, `kubectl`, and Go. If you use
[mise](https://mise.jdx.dev), `mise install` pins the Go and kubebuilder
versions this repo is developed against; everything else the build needs is
downloaded into `bin/` by the Makefile.

Install the CRD and run the operator against your current kube context:

```bash
make install && make run
```

Then, in another shell, replace the placeholder credentials in
`config/samples/` and apply the resources:

```bash
kubectl apply -k config/samples/
```

The samples apply as-is on a throwaway cluster, but the agents cannot
authenticate to Buildkite until the placeholder token is replaced. Replace all
sample credentials before using them elsewhere.

To run the operator *in* the cluster instead of on your laptop, build and push
an image, then deploy it:

```bash
make docker-build docker-push IMG=<your-registry>/buildkite-operator:tag
make deploy IMG=<your-registry>/buildkite-operator:tag
```

or install the Helm chart:

```bash
make helm-deploy IMG=<your-registry>/buildkite-operator:tag
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
| `spec.agentTokenSecretRef` | yes | — | Secret name and key holding the Buildkite agent token, exposed to agents as `BUILDKITE_AGENT_TOKEN`. |
| `spec.resources` | no | — | Compute resources for each agent container. |
| `spec.cacheStoreRef.name` | no | — | Name of a `CacheStore` in the same namespace. Cache-enabled pools require Buildkite agent 3.128.0 or newer. |

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
resources, termination grace period, or cache configuration roll through idle
Pods without interrupting busy agents. `maxRunners` remains a hard cap, so a
replacement at the cap can briefly reduce the warm buffer by one. Deleting the
pool gracefully terminates all of its Pods through owner-reference garbage
collection.

When a referenced `CacheStore` exists, the operator injects its S3 URL and
credential Secret references even while the store starts. A store outage does
not stop agents. If the reference is missing, a new pool waits and all existing
agent Pods are left untouched. `CacheStoreReady` reports this dependency
separately from the agent `Ready` condition. Removing the reference rolls the
cache variables out through confirmed-idle Pods.

Buildkite must also be configured with an `agent_managed` cache registry, and
pipelines must explicitly save and restore cache entries. The operator cannot
configure that Buildkite-side registry using an agent token.

This version replaces the earlier Deployment-based `v1alpha1` implementation
without an in-place migration. Delete and recreate existing RunnerPools when
upgrading so their legacy Deployments do not continue running alongside the new
directly managed Pods.

## CacheStore

`CacheStore` runs a persistent, single-node Garage v2.3 instance and configures
an S3 lifecycle rule for Buildkite agent cache objects. A store can be shared
by multiple `RunnerPool` resources in its namespace.

| Field | Required | Default | Description |
| --- | --- | --- | --- |
| `spec.image` | no | `dxflrs/garage:v2.3.0` | Garage image; override for a private mirror. |
| `spec.bucket` | no | `buildkite-cache` | Immutable S3 bucket name. |
| `spec.rpcSecretRef` | yes | — | Immutable Secret and key containing exactly 64 hexadecimal characters. |
| `spec.credentialsSecretRef` | yes | — | Immutable Secret and keys containing Garage's S3 access-key ID and secret key. |
| `spec.storage.size` | yes | — | Immutable capacity of the single `ReadWriteOnce` PVC. |
| `spec.storage.storageClassName` | no | cluster default | Immutable StorageClass name. |
| `spec.retentionDays` | no | `2` | Object expiry in day boundaries; two days is approximately 24–48 hours. |
| `spec.resources` | no | — | Compute resources for Garage. |
| `spec.lifecycleImage` | no | `public.ecr.aws/aws-cli/aws-cli:2.27.41` | Pinned AWS CLI image used by the lifecycle Job. |

Both credential Secrets must set `immutable: true`. Garage access-key IDs must
contain at least eight ASCII letters, digits, `.`, `_`, or `-`; secret keys
must contain at least 16 printable ASCII characters. Garage cannot rotate an
existing key's secret on a retained data volume. To change credentials, create
a new `CacheStore` or deliberately remove the old PVC and its data.

The store expires objects after `retentionDays` and aborts incomplete multipart
uploads after one day. Garage evaluates lifecycle rules daily. Buildkite's
restore-time self-copy refreshes hot objects' modification times.

The StatefulSet explicitly retains its PVC on deletion and scale-down. Deleting
a `CacheStore` removes its workloads and Services but leaves
`data-<store>-0`; delete or snapshot that PVC manually when appropriate. The
store is single-node and non-HA, uses plaintext HTTP inside the cluster, and
does not provide backup, restore, TLS, or credential rotation.

## Development

```bash
make test        # unit tests against envtest
make test-e2e    # deploys to a throwaway kind cluster and checks Pods and cache storage
make lint        # golangci-lint
make build       # regenerate manifests and build the manager binary
```

CI runs `lint`, a codegen drift check, `test` and `test-e2e` — see
[.buildkite/pipeline.yml](.buildkite/pipeline.yml). The drift check fails if
generated CRDs, RBAC or deepcopy code are stale, so run `make manifests generate`
after touching API types under [api/v1alpha1](api/v1alpha1) or
`+kubebuilder:rbac` markers under [internal/controller](internal/controller).

The Helm chart in `dist/chart` is generated from `config/`, not maintained by
hand. Regenerate it after any API or RBAC change:

```bash
make helm
```

Note that `make test-e2e` deletes its kind cluster when it finishes, which also
clears your kubeconfig's current context. Run `kubectl config use-context ...` to
point back at your own cluster.

## License

MIT — see [LICENSE](LICENSE).

Managed stores run Garage, which is AGPL-3.0 software distributed separately
in the `dxflrs/garage` container image.
