# Standalone Buildkite runner chart

## Summary

Add a hand-maintained Helm chart under `charts/buildkite-operator` that installs usable Buildkite runners and queue-driven autoscaling as one customer-facing unit. The chart uses a standard Kubernetes `Deployment` scaled by KEDA without depending on a custom API or operator.

## Requirements

- Keep one runner warm by default and scale toward a customer-supplied positive maximum from Buildkite queue demand.
- Require a Buildkite queue and either a token value or existing Secret reference.
- Scale from the Buildkite Agent Metrics API's `scheduled + running` counts so running jobs continue to reserve capacity.
- Vendor KEDA 2.20.0 and its CRDs so a first installation works without another chart. Allow `keda.enabled=false` when a compatible cluster installation already exists.
- Retain KEDA CRDs on uninstall and remove namespaced KEDA resources while its controller is still available to clear finalizers.
- Offer `standard`, `kata`, and `sysbox` runner profiles. Do not install Kata or Sysbox because both mutate node runtime configuration; document their RuntimeClass and node prerequisites.
- Keep AWS/EKS lab resources, observations, and credentials metadata out of the chart.
- Verify direct-token, existing-Secret, disabled-runner, invalid-input, first-install, KEDA readiness, runner Pod creation, and clean uninstall behavior.

## Implementation

### Runner workload

Render an `apps/v1` Deployment for long-lived Buildkite agents. The standard profile runs the agent directly. Kata and Sysbox add their tested RuntimeClass, scheduling constraints, native Docker sidecar, shared socket/workspace volumes, and runtime-specific privilege settings.

Agents receive a long termination grace period and use the agent's first-SIGTERM graceful drain behavior. KEDA/HPA chooses scale-in victims, so the configured maximum is a desired-replica bound rather than a hard bound on live terminating Pods.

### Autoscaling

Render a KEDA `TriggerAuthentication` and `ScaledObject` targeting the runner Deployment. Two `metrics-api` triggers read the queue's `scheduled` and `running` values from `https://agent.buildkite.com/v3/metrics`; a scaling modifier sums them with target `1`. Default to `minReplicaCount: 1`, a 10-second poll, 60-second zero cooldown, and a 30-second scale-down stabilization window.

Direct-token mode creates one Secret containing the raw agent token and `Authorization: Token <token>` value. Existing-secret mode accepts separate agent and metrics Secret references because Helm cannot derive the prefixed authorization value from an existing Secret.

### Standalone KEDA lifecycle

Vendor the pinned KEDA subchart. Copy its rendered CRDs into the parent chart's `crds/` directory and disable the subchart's templated CRDs so Helm can validate the chart's KEDA resources during first installation. A pre-delete hook with namespace-scoped RBAC deletes and waits for the `ScaledObject` and `TriggerAuthentication` before Helm removes KEDA, preventing orphaned finalizers.

### Verification

- `make test-helm` validates standard, Kata, Sysbox, direct-token, existing-secret, disabled, and rejected-input renders, then lints the chart with bundled KEDA.
- `make test-helm-e2e` installs the complete chart in isolated Kind, waits for KEDA, verifies the Deployment, scaling resources, Secret, and runner Pod, then confirms uninstall completes without leaving the namespace stuck.
- Existing Go lint, generation, and unit suites continue to validate the repository's separately runnable operator implementation.
