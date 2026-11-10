# Deployment

## Production secret management

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

## Deletion-cost admission policy

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

## Installing Kata and Sysbox

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

## Custom agent images

If you replace the agent `image`, check that it still has what the chart's
scripts use. With [step images](../README.md#step-images) enabled, the image
the agent runs in needs the `docker` CLI and `setsid`, which `buildkite/agent`
images have.

If you replace `docker.image` on a pool that sets `docker.agentRuntimeImage`,
it must be Docker Engine 29 or later, with support for the containerd image
store. See [Agent runtime image](../README.md#agent-runtime-image).

## OCI Accelerator

With `ociAccelerator.enabled`, the chart installs:

- A StatefulSet running `ociAccelerator.replicas` accelerator replicas
  (default 1), and a ClusterIP Service that the Docker daemons use as their
  HTTPS proxy.
- A headless Service providing stable per-Pod DNS names for the StatefulSet,
  also used for discovery when peering is enabled.
- A NetworkPolicy admitting only this release's runner Pods
  (`networkPolicy.enabled`). Enforcement requires a network plugin that
  supports NetworkPolicy.

Accelerator replicas prefer spreading across nodes, without needing a separate
node for each replica. See
[Image pull caching](../README.md#image-pull-caching).

With peering enabled:

- Runners use the accelerator Service on port 3128, and the headless Service
  also exposes the peer port, 7443.
- The NetworkPolicy allows port 7443 only between this release's accelerator
  replicas.
- Changing the replica count changes the peer seed list and rolls the
  accelerator.
- Switching peering on or off rolls the StatefulSet, without changing the
  Service runners use or the CA, so runner Pods need no restart.
- The accelerator Pods' 40-second termination grace period covers the default
  proxy and peer drains. Keep any `OCI_ACCELERATOR_SHUTDOWN_TIMEOUT` override
  below 20 seconds, to leave time for cleanup.

## OCI Accelerator CA

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
