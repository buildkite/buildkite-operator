# buildkite-operator

A Kubernetes operator for Buildkite runners.

Declare a pool of Buildkite agents as a Kubernetes resource, and the operator
keeps a Deployment of agents running against the queue you name:

```yaml
apiVersion: buildkite.com/v1alpha1
kind: RunnerPool
metadata:
  name: linux-builders
spec:
  queue: linux-amd64
  replicas: 3
  agentTokenSecretRef:
    name: buildkite-agent-token
    key: token
```

```console
$ kubectl get runnerpools
NAME             QUEUE         DESIRED   READY   AGE
linux-builders   linux-amd64   3         3       2m
```

> **Status: early.** The API is `v1alpha1` and will change. The operator does not
> talk to the Buildkite API yet — it reconciles Kubernetes resources only, and
> passes your agent token through to the agents by secret reference.

## Quickstart

Requires a Kubernetes cluster, `kubectl`, and Go. If you use
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
| `spec.replicas` | no | `1` | Number of agents to run. Also settable with `kubectl scale runnerpool/<name> --replicas=N`. |
| `spec.image` | no | `buildkite/agent:3` | Agent container image. No command or args are set, so the image's entrypoint has to start the agent. |
| `spec.agentTokenSecretRef` | yes | — | Secret name and key holding the Buildkite agent token, exposed to agents as `BUILDKITE_AGENT_TOKEN`. |
| `spec.resources` | no | — | Compute resources for each agent container. |

Status reports `readyReplicas`, `observedGeneration`, and a `Ready` condition
derived from the underlying Deployment's availability — when agents can't run,
the Deployment's own reason is surfaced:

```bash
kubectl describe runnerpool linux-builders
```

Each pool owns one Deployment named `<pool>-agent`, labelled
`buildkite.com/runner-pool=<pool>`. Deleting the pool deletes the Deployment.

## Development

```bash
make test        # unit tests against envtest
make test-e2e    # deploys to a throwaway kind cluster and asserts a pool goes Ready
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
