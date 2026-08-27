# buildkite-operator

A Kubernetes operator for Buildkite runners.

Declare a pool of Buildkite agents as a Kubernetes resource, and the operator
keeps a warm buffer of isolated Docker-in-Docker runner Pods against the queue
you name:

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

Each runner Pod has a privileged, rootful Docker daemon and an unprivileged
supervisor. The supervisor runs the Buildkite agent inside that private daemon,
where jobs can launch their own Docker containers without sharing a node-level
Docker socket.

> [!WARNING]
> Rootful privileged Docker-in-Docker is not a hard security boundary. A job
> has root-equivalent control of its Pod's daemon, and the privileged daemon can
> potentially compromise its Kubernetes node. Use dedicated tainted nodes or
> VM-isolated workers for untrusted builds.

## Quickstart

Requires Kubernetes 1.29 or newer, permission to run privileged Pods,
`kubectl`, and Go. If you use
[mise](https://mise.jdx.dev), `mise install` pins the Go and kubebuilder
versions this repo is developed against; everything else the build needs is
downloaded into `bin/` by the Makefile.

Install the CRD and run the operator against your current kube context:

```bash
make install && make run
```

Then, in another shell, create an agent token secret and a pool:

```bash
kubectl create secret generic buildkite-agent-token --from-literal=token=$YOUR_AGENT_TOKEN
kubectl apply -f config/samples/v1alpha1_runnerpool.yaml
```

The sample includes a placeholder token secret of its own, so it applies
cleanly on a throwaway cluster — the agents will just fail to authenticate.

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
| `spec.terminationGracePeriodSeconds` | no | `3600` | Pod shutdown budget. The supervisor reserves 10 seconds for forced cleanup and daemon shutdown. |
| `spec.agentImage` | no | `buildkite/agent:3` | Agent image run inside the Pod-local Docker daemon. It must provide the Buildkite agent health server and graceful SIGTERM behavior; Buildkite agent v3.72.0 or newer is required. |
| `spec.singleUse` | no | `false` | Run the agent with `start --disconnect-after-job`. After one job, the supervisor replaces the exited inner agent container while retaining the Pod-local cache and workspace. |
| `spec.agentTokenSecretRef` | yes | — | Secret name and key holding the Buildkite agent token, exposed to agents as `BUILDKITE_AGENT_TOKEN`. |
| `spec.resources` | no | — | CPU, memory, and ephemeral-storage envelope applied to the privileged daemon. It accounts for dockerd, the agent, and all nested job containers. |
| `spec.docker.daemonImage` | no | `docker:29.7.2-dind` | Rootful daemon image. It must support the official dind entrypoint and the controller's explicit `dockerd` invocation. |
| `spec.docker.supervisorImage` | no | `docker:29.7.2-cli` | Supervisor image. It must provide a POSIX `/bin/sh` and a Docker CLI compatible with the daemon. |
| `spec.docker.configSecretRef` | no | — | Name of a `kubernetes.io/dockerconfigjson` Secret used for Kubernetes, agent, and job image pulls. |
| `spec.nodeSelector` | no | — | Node labels required by runner Pods. |
| `spec.tolerations` | no | — | Taints tolerated by runner Pods. |

Each directly owned runner Pod contains a restartable native `dockerd` sidecar
and the supervisor. The supervisor keeps one inner container named
`buildkite-agent` running, publishes its health endpoint to the Pod network,
adopts it after a supervisor-only restart, and streams its logs through the
Kubernetes `supervisor` container. After the inner agent exits, the supervisor
removes all remaining containers, prunes unused custom networks, waits five
seconds, and starts a replacement. Images, BuildKit and layer caches, named
volumes, and the workspace remain available until the Pod itself is replaced.
With `singleUse: true`, the agent runs with `start --disconnect-after-job`, so
this replacement happens after every completed job.

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

### Storage and bind mounts

Docker data, the socket, and `/workspace` use separate Pod-local `emptyDir`
volumes. They survive inner agent replacement but are discarded with the Pod;
there is no persistent cache or workspace across a rollout or reschedule.

Docker resolves bind-mount source paths in the daemon container. The operator
therefore guarantees matching paths in the daemon and agent only for:

- `/workspace/**`, including checkouts in `/workspace/builds` and downloaded
  plugins in `/workspace/plugins`;
- `/var/run/docker.sock`;
- `/docker-config` when registry credentials are configured.

Normal Docker plugin checkout mounts work beneath `/workspace`. Agent-only
paths such as `/tmp`, image-local binaries, SSH sockets, or custom paths cannot
be bind-mounted into job containers unless they are first copied under a
shared path. This also applies to advanced Docker plugin options that mount
arbitrary agent-local paths.

### Private registries

Create one standard Docker config Secret and reference it from the pool:

```bash
kubectl create secret docker-registry registry-credentials \
  --docker-server=registry.example.com \
  --docker-username="$REGISTRY_USERNAME" \
  --docker-password="$REGISTRY_PASSWORD"
```

```yaml
spec:
  docker:
    configSecretRef:
      name: registry-credentials
```

The Secret is also added to `imagePullSecrets`. Its `config.json` is mounted
read-only into the supervisor and inner agent, so jobs that run `docker login`
must select a different writable `DOCKER_CONFIG`.

### Dedicated runner nodes

Resource limits constrain accounting but do not make privileged containers a
safe hostile-code boundary. Label and taint dedicated runner nodes, then target
them explicitly:

```yaml
spec:
  nodeSelector:
    buildkite.com/runner: "true"
  tolerations:
    - key: buildkite.com/runner
      operator: Equal
      value: "true"
      effect: NoSchedule
```

Status reports `totalRunners`, `idleRunners`, `busyRunners`, `readyRunners`,
`observedGeneration`, and a `Ready` condition. `idleRunners` includes only
Pods whose daemon and published agent health endpoint are ready and whose
`/status.json` response confirms they are idle. Unreachable and warming Pods
are the difference between the total and the confirmed busy/idle counts:

```bash
kubectl describe runnerpool linux-builders
```

Each pool directly owns Pods named `<pool>-agent-*`, labelled
`buildkite.com/runner-pool=<pool>`. Changes to the queue, images, registry
credentials, token reference, resources, scheduling settings, or termination
grace period roll through idle Pods without interrupting busy agents.
`maxRunners` remains a hard cap, so a replacement at the cap can briefly reduce
the warm buffer by one. Deleting the pool gracefully terminates all of its Pods
through owner-reference garbage collection.

When upgrading from the directly managed agent-Pod implementation, the
operator treats old Pods as stale and replaces them after they report idle.

That direct-Pod version replaced an earlier Deployment-based `v1alpha1` API
without an in-place migration. Delete and recreate existing RunnerPools when
upgrading so their legacy Deployments do not continue running alongside the new
directly managed Pods.

## Development

```bash
make test        # unit tests against envtest
make test-e2e    # deploys to a throwaway kind cluster and checks Pod ownership/lifecycle
make lint        # golangci-lint
make build       # regenerate manifests and build the manager binary
```

CI runs `lint`, a codegen drift check, `test` and `test-e2e` — see
[.buildkite/pipeline.yml](.buildkite/pipeline.yml). The drift check fails if
generated CRDs, RBAC or deepcopy code are stale, so run `make manifests generate`
after touching [api/v1alpha1/runnerpool_types.go](api/v1alpha1/runnerpool_types.go)
or the `+kubebuilder:rbac` markers in
[internal/controller/runnerpool_controller.go](internal/controller/runnerpool_controller.go).

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
