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
to take over another runner Pod, or the OCI accelerator proxy, by changing its
image.

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
