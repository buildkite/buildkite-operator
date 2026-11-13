# Appendices

Supporting details for the [README](../README.md), grouped by purpose.

## Setup

### Production secret management

Helm stores supplied values in its release data. For production secret
management, create the Secrets separately in the release namespace and
reference them instead:

```bash
helm upgrade --install buildkite-operator ./charts/buildkite-operator \
  --namespace buildkite-runner-stack \
  --create-namespace \
  --set-string runnerPools.linux.queue=<queue> \
  --set runnerPools.linux.maxReplicas=<maximum> \
  --set-string agentToken.existingSecret.name=<agent-secret> \
  --set-string metricsToken.existingSecret.name=<metrics-secret>
```

The metrics Secret key must contain the complete `Authorization` value in the
form `Token <cluster-agent-token>`.

### Installing Kata and Sysbox

Kata and Sysbox are host runtimes, so the chart deliberately does not install
them or modify containerd. Like KEDA, they are cluster-wide installs, done once
per cluster before installing the chart. See
[Runtimes](../README.md#runtimes) for what each runtime needs.

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

### Custom agent images

If you replace the agent `image`, check that it still has what the chart's
scripts use. With [step images](../README.md#step-images) enabled, the image
the agent runs in needs the `docker` CLI and `setsid`, which `buildkite/agent`
images have.

### Resources the chart creates

For each runner pool, named `<release>-<pool>`:

- A `Deployment` of runner Pods, labeled `buildkite.com/runner-pool: <pool>`.
- A KEDA `ScaledObject` that scales it.

Shared by all pools in a release:

- The agent token Secret, when you set `agentToken.value` or
  `metricsToken.value` rather than an existing Secret.
- A KEDA `TriggerAuthentication` for the Agent Metrics API.
- The deletion-cost sidecar's ServiceAccount, Role, RoleBinding and script
  ConfigMap.
- The cluster-scoped deletion-cost `ValidatingAdmissionPolicy` and binding.
  See [Deletion-cost admission policy](#deletion-cost-admission-policy).
- ConfigMaps for the ephemeral agent and step image scripts, when a pool uses
  them.
- The registry credentials Secret, when you set `registryCredentials.auths`.
  See [Registry credentials](#registry-credentials).

With OCI Accelerator enabled and used by a pool, the accelerator's
StatefulSet, Services, NetworkPolicy and CA objects. See
[OCI Accelerator resources and peering](#oci-accelerator-resources-and-peering)
and [OCI Accelerator CA](#oci-accelerator-ca).

## Running jobs

### Ephemeral agents

How each runtime replaces the agent after every job. See
[Ephemeral agents](../README.md#ephemeral-agents).

- `standard`: a small loop in the agent container empties the build and plugin
  directories, then runs `buildkite-agent start --disconnect-after-job` again.
  The container never restarts, so restart backoff doesn't delay the next job.
  The agent image needs `/bin/sh`.
- `dind`, `kata`, `sysbox`: a supervisor starts each agent as a fresh container
  in the Pod's Docker daemon. After each job it removes the job's containers,
  networks and volumes, and clears the `/buildkite` workspace. Image and build
  caches persist until the [cache pruning](#cache-pruning) threshold is reached.

Ephemeral agents also behave as follows:

- If cleanup fails, no new agent starts until it succeeds.
- On SIGTERM, from scale-in, upgrades or node scale-down, the current agent
  finishes its job within `terminationGracePeriodSeconds`, and no further agent
  starts.
- While one agent replaces the next, the deletion-cost sidecar marks the Pod
  busy until the new agent reports idle, so scale-in prefers other Pods.

#### Cache pruning

With ephemeral `dind`, `kata` and `sysbox` agents, the supervisor measures
allocated disk usage in `/var/lib/docker` after ordinary cleanup and before
starting the next agent. At `docker.pruneThresholdPercent` of
`docker.storage.data` (default 80% of 35Gi, or 28Gi), it prunes all unused Docker
images and build cache. It retains the configured `image` and optional
`docker.agentRuntimeImage`.

The workspace cleanup container also measures Docker data through a read-only
mount using `du`, not the backing filesystem's capacity reported by `df`. It
uses its existing root permissions to traverse private image directories. The
supervisor adds no capabilities and does not mount Docker data.

The agent `image` must provide `du`. Custom daemon images must keep their image
and build data beneath `/var/lib/docker` for this measurement to cover it. After
pruning, a second short-lived container measures the remaining usage.

- If measurement fails, the supervisor logs the failure and prunes caches.
- If pruning fails, the supervisor delays agent startup and retries cleanup.
  Each retry measures usage again and skips pruning if usage is below the
  threshold, even if a previous prune only partially succeeded.
- If pruning succeeds but usage remains above the threshold, the supervisor
  warns and starts the next agent without repeatedly pruning.
- Logs report usage before and after pruning, and pruning duration.

The threshold triggers cleanup, not a storage reservation or an admission
limit. Leave enough headroom for a job's peak storage use. A single job can
still exhaust storage or trigger eviction because pruning only runs between
jobs. Cached images, including locally built tags, remain visible to later jobs
until pruning or Pod removal.

### Step images

On `dind`, `kata` and `sysbox` runners, the agent runs each job through a
script from the chart instead of `buildkite-agent bootstrap`. When the job has
a step image or a default step image, the script starts a step container in
the Pod's Docker daemon. See [Step images](../README.md#step-images).

The step container:

- Runs one full `buildkite-agent bootstrap`: plugins, checkout, hooks and
  commands.
- Mounts the `/buildkite` workspace at the same path, so it sees the checkout,
  plugins, Job API socket and agent binary.
- Gets the job's environment, the Pod's Docker daemon and the Docker client
  configuration (`DOCKER_CONFIG`), like the agent.
- Carries environment and working-directory changes from hooks through to the
  command phase.
- Is named `buildkite-step-<job ID>` and labeled `buildkite.com/job-id`, is
  stopped when the job is cancelled and removed when the job finishes.

Agent 4.8 can still bring back a variable a hook unset, if it was set when the
bootstrap started, because its subprocess layer merges the original
environment back in. Variables that an earlier hook created and a later one
unset aren't affected.

### Agent runtime image

See [Agent runtime image](../README.md#agent-runtime-image) for what it does and
how to set it.

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

Both images are pulled only when missing, so a cached tag isn't refreshed for
each job. Coordinate with active jobs before changing either image or
upgrading runner Pods.

#### How it works

With `docker.agentRuntimeImage` set, the supervisor starts each agent in the
runtime image and mounts the agent `image` into it with a Docker `type=image`
mount.

- Docker mounts the agent image's filesystem read-only at
  `/opt/buildkite-agent-source`, rather than overlaying it on the runtime
  image's root.
- At startup, only the agent binary is copied to
  `/buildkite/bin/buildkite-agent`, and the agent runs that copy.
- That path is first on `PATH` and is the agent's `BUILDKITE_BIN_PATH`, so
  Docker and Docker Compose plugins and step containers can bind-mount it
  without the source image's mount.
- No extraction container or combined image is needed, and the workspace
  cleanup between jobs is unchanged.
- The supervisor refuses to start on a daemon without the containerd image
  store, rather than falling back to another way of getting the binary.

If you replace `docker.image` on a pool that sets `docker.agentRuntimeImage`,
it must be Docker Engine 29 or later, with support for the containerd image
store.

### Bind mounts

On `dind`, `kata` and `sysbox` runners, the Docker daemon resolves bind-mount
sources in its own container, which shares only the `/buildkite` workspace with
the agent. See [Bind mounts](../README.md#bind-mounts).

So that the Docker and Docker Compose plugins' `mount-buildkite-agent` option
works, each agent copies its binary to `/buildkite/bin/buildkite-agent` and
puts that directory first on `PATH`, where the plugins look for it. This is why
the agent image needs `/bin/sh`.

## Scaling

### Scale-in and node autoscaling

See [Autoscaling](../README.md#autoscaling).

#### Scale-in preference

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
[Deletion-cost admission policy](#deletion-cost-admission-policy).

#### Node autoscaling

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

### Deletion-cost admission policy

Each runner Pod's deletion-cost sidecar holds a Kubernetes API token so it can
patch its Pod's annotations. See
[Scale-in preference](../README.md#scale-in-preference).

Deployment Pod names are generated, so the sidecar's Role can't be limited to
its own Pod and lets its token patch every Pod in the release namespace. A job
that escapes to its node could read the tokens of the Pods there, and use one
to take over another runner Pod, or the accelerator, by changing its image.

To limit this, the chart installs a `ValidatingAdmissionPolicy` and binding,
both named `<namespace>-<release>-buildkite-operator-deletion-cost`. Using the
Pod name that the kubelet binds into each sidecar's token, the policy allows a
sidecar to patch only:

- Its own Pod.
- The `controller.kubernetes.io/pod-deletion-cost` and
  `cluster-autoscaler.kubernetes.io/safe-to-evict` annotations, leaving the
  spec, labels, finalizers, owner references and every other annotation
  unchanged.

The policy and binding are cluster-scoped, so installing the chart needs
Kubernetes 1.30 or later and permission to create them. If you can't grant
that:

- Set `deletionCost.admissionPolicy.enabled: false`.
- The sidecar still works, but its token can change any Pod in the namespace.
- Install the chart in a namespace dedicated to runners.

## Images and registries

### Registry credentials

See [Registry credentials](../README.md#registry-credentials).

- The CA hook Jobs use a temporary copy of the Secret,
  `<release>-buildkite-operator-registry-credentials-hook`, because they run
  before the Secret exists on install and after it's deleted on uninstall.
- On `dind`, `kata` and `sysbox` runners, the Docker client configuration
  lives in `/etc/buildkite-agent/docker`, set as `DOCKER_CONFIG` for the agent
  and, with ephemeral agents, for the supervisor and every agent container.

### OCI Accelerator resources and peering

With `ociAccelerator.enabled`, the chart installs:

- A StatefulSet running `ociAccelerator.replicas` accelerator replicas
  (default 1), and a ClusterIP Service that the Docker daemons use as their
  HTTPS proxy.
- A headless Service providing stable per-Pod DNS names for the StatefulSet,
  also used for discovery when peering is enabled.
- A NetworkPolicy allowing this release's runner Pods to reach the accelerator
  on port 5128 (`networkPolicy.enabled`). Enforcement requires a network plugin
  that supports NetworkPolicy.

Accelerator replicas prefer spreading across zones and nodes, without needing
a separate zone or node for each replica. Nodes without a
`topology.kubernetes.io/zone` label still spread by node. See
[Image pull caching](../README.md#image-pull-caching).

The accelerator Service sets `trafficDistribution` to `PreferSameZone`, or
`PreferClose` before Kubernetes 1.34, so each runner's connections go to a
ready replica in its zone:

- A zone with no ready replica uses replicas in any zone.
- Each zone's replicas take all of that zone's pulls, so a zone with many
  runners and one replica can saturate it. Add replicas, or compare
  per-replica request rates in [metrics](#oci-accelerator-metrics).
- kube-proxy honors the setting from Kubernetes 1.31, and earlier versions
  spread connections across all replicas. If your network plugin replaces
  kube-proxy, check that it supports `trafficDistribution`.
- With [peering](#peering), a layer crosses zones at most once per replica,
  when that replica fetches it from a peer, instead of on every pull.

#### OCI Accelerator metrics

| Setting | Description |
| --- | --- |
| `ociAccelerator.metrics.remote` | (default `false`) Listen on `0.0.0.0:9090` instead of loopback, allowing remote scrapes. |
| `ociAccelerator.networkPolicy.metricsFrom` | (default `[]`) Kubernetes NetworkPolicyPeer sources allowed to reach TCP 9090 when remote metrics and the chart's NetworkPolicy are enabled. |
| `ociAccelerator.podAnnotations` | (default `{}`) Annotations added to every accelerator Pod. The chart's registry-credentials checksum takes precedence if a key conflicts. |

For example, admit collector Pods from a monitoring namespace:

```yaml
ociAccelerator:
  enabled: true
  metrics:
    remote: true
  networkPolicy:
    enabled: true
    metricsFrom:
      - namespaceSelector:
          matchLabels:
            kubernetes.io/metadata.name: monitoring
        podSelector:
          matchLabels:
            app: metrics-collector
```

- Selectors in one list item combine with AND. Separate items combine with OR.
  A Pod selector without a namespace selector selects the release namespace.
- An empty `metricsFrom` adds no metrics ingress rule. With
  `networkPolicy.enabled: false`, the chart creates no NetworkPolicy and
  ignores `metricsFrom`. Other policies determine access, and without an
  applicable policy incoming traffic is unrestricted. Policies are additive.
- The metrics listener also serves `/livez` and `/readyz`, all without
  authentication. Keep it on a private network with appropriate restrictions.
  Health probes continue to use loopback in either mode.
- Scrape each replica's Pod IP. The chart does not expose metrics through its
  Services or create monitoring custom resources. Configure your collector's
  discovery separately, using `podAnnotations` where supported.

The [peering example](../charts/buildkite-operator/examples/peering/values.yaml)
includes Datadog OpenMetrics discovery annotations. Match its selectors to
your scraping Agents, not the Datadog Operator. Host-networked Agents may
appear as node traffic, depending on your network plugin, so verify how your
cluster enforces their access. Collecting all metrics can increase custom
metric costs.

See OCI Accelerator's
[metrics reference](https://github.com/buildkite/oci-accelerator/blob/v0.5.0/docs/metrics.md)
for metric names.

#### Peering

With `ociAccelerator.peering.enabled`:

- The chart sets up peer discovery and mutual TLS with the release's CA, and
  runners keep using the same accelerator Service.
- Runners use the accelerator Service on port 5128, and the headless Service
  also exposes the peer port, 5130.
- The NetworkPolicy allows port 5130 only between this release's accelerator
  replicas.
- Changing the replica count changes the peer seed list and rolls the
  accelerator.
- Switching peering on or off rolls the StatefulSet, without changing the
  Service runners use or the CA, so runner Pods need no restart.
- The accelerator Pods' 40-second termination grace period covers the default
  proxy and peer drains. Keep any `OCI_ACCELERATOR_SHUTDOWN_TIMEOUT` override
  below 20 seconds, to leave time for cleanup.

The chart configures peer discovery for each accelerator replica. See
[Peering](../README.md#peering).

- Each replica is seeded with every replica's DNS name from the StatefulSet's
  headless Service, including its own, which OCI Accelerator ignores.
- Seeds are DNS names, not Pod IPs, so replaced Pods can find each other again.
- Pods start in parallel, and peer DNS records are published before the Pods
  are ready.
- No Kubernetes API access or discovery sidecar is needed.
- Discovery and cache listings refresh asynchronously, so a new replica can
  fetch from origin before it learns what its peers have.

#### Cache storage

- The cache is an `emptyDir` on the accelerator's node, limited to
  `cache.size` (default 20Gi). It survives container restarts, but starts
  empty when the accelerator Pod is replaced.
- The accelerator requests `cache.size` of `ephemeral-storage`, so size it to
  fit beside runner Pods, or place the accelerator with `nodeSelector` and
  `tolerations`.
- Keep `cache.maxBytes` below `cache.size`.
- Tag lookups are cached in memory for 30 seconds, so a tag pushed in one step
  can still resolve to its old digest in the next. To turn this off, set
  `OCI_ACCELERATOR_CACHE_MUTABLE_TTL: "0s"` in `ociAccelerator.extraEnv`.

Pass other `OCI_ACCELERATOR_*` settings through `ociAccelerator.extraEnv`. See
OCI Accelerator's
[cache storage](https://github.com/buildkite/oci-accelerator/blob/v0.5.0/docs/deployment.md#cache-storage) and
[settings](https://github.com/buildkite/oci-accelerator/blob/v0.5.0/docs/settings.md) docs.

See OCI Accelerator's
[peer discovery](https://github.com/buildkite/oci-accelerator/blob/v0.5.0/docs/deployment.md#peer-discovery)
docs for how peering works and its limits.

### OCI Accelerator CA

The accelerator signs registry certificates with its own root CA, which it
loads from a Secret in the release namespace. It never generates one itself.
Runner Pods trust only the CA's certificate, which they mount from a separate
ConfigMap, `<release>-buildkite-operator-oci-accelerator-ca-cert`, so only the
accelerator references the Secret holding the private key.

By default the chart generates the CA with Helm hook Jobs:

- Before install and every upgrade, a Job runs OCI Accelerator's `init-ca` and
  stores the result in the Secret
  `<release>-buildkite-operator-oci-accelerator-ca`, unless it already exists,
  so the CA is created once and then kept.
- The same Job copies the certificate from the Secret into the ConfigMap,
  creating or updating it.
- After `helm uninstall`, a second Job deletes the ConfigMap and the Secret.
  `helm uninstall --no-hooks` leaves them behind.
- The Jobs run with a short-lived ServiceAccount that may create Secrets and
  ConfigMaps, but may read or delete only that Secret and ConfigMap, and update
  only the ConfigMap.
- Helm itself never renders or stores the private key.

To rotate the CA, delete the Secret, run `helm upgrade`, then restart the
accelerator StatefulSet and the runner Deployments.

To manage the CA yourself instead, for example to keep it across reinstalls,
create it once and store it in a Secret in the release namespace. This runs
`init-ca` in a throwaway container and copies the files out:

```bash
mkdir -m 0700 oci-accelerator-ca
docker run --rm --entrypoint /bin/sh buildkite/oci-accelerator:v0.5.0 -ec \
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
certificate, then restart the accelerator StatefulSet and the runner
Deployments.

The Docker daemons trust OCI Accelerator's CA for every host, not only
`registries`, because Docker doesn't read `/etc/docker/certs.d` for Docker Hub
with the classic image store that `sysbox` uses. The accelerator's node holds
the CA private key that every accelerated daemon trusts, including those of
`kata` and `sysbox` pools running untrusted jobs. See OCI Accelerator's
[security model](https://github.com/buildkite/oci-accelerator/blob/v0.5.0/docs/deployment.md#security-model).

The CA's private key stays off runner Pods:

- A node's kubelet can read every key of any Secret that a Pod on the node
  references, so a job that escapes to its node can read those Secrets.
- Runner Pods reference only the certificate's ConfigMap, never the CA Secret.
- The private key is mounted only in the accelerator, and held briefly by the
  hook Job that generates or copies it.
- The hook Jobs that generate, copy and delete the CA use the accelerator's
  `nodeSelector` and `tolerations`.
- Without the [deletion-cost admission policy](#deletion-cost-admission-policy),
  an escaped job could instead use a runner Pod's token to change the
  accelerator Pod's image.

Pods read the CA at startup, so after replacing it, restart the accelerator
StatefulSet and the runner Deployments.
