# Standalone Buildkite runner chart

## Summary

Add a hand-maintained Helm chart under `charts/buildkite-operator` that installs usable Buildkite runners and queue-driven autoscaling as one customer-facing unit. The chart uses a standard Kubernetes `Deployment` scaled by KEDA without depending on a custom API or operator.

## Requirements

- Keep one runner warm by default and scale toward a customer-supplied positive maximum from Buildkite queue demand.
- Require a Buildkite queue and either a token value or existing Secret reference.
- Scale from the Buildkite Agent Metrics API's `scheduled + running` counts so running jobs continue to reserve capacity.
- Require the supported KEDA 2.20.0 release to be installed separately and configured to watch the release namespace.
- Validate that KEDA's `ScaledObject` and `TriggerAuthentication` APIs are discoverable before rendering runner resources.
- Offer `standard`, `kata`, and `sysbox` runner profiles. Do not install Kata or Sysbox because both mutate node runtime configuration; document their RuntimeClass and node prerequisites.
- Keep AWS/EKS lab resources, observations, and credentials metadata out of the chart.
- Verify the missing-KEDA failure, direct-token, existing-Secret, disabled-runner, invalid-input, KEDA readiness, runner Pod creation, and independent uninstall behavior.

## Implementation

### Runner workload

Render an `apps/v1` Deployment for long-lived Buildkite agents. The standard profile runs the agent directly. Kata and Sysbox add their tested RuntimeClass, scheduling constraints, native Docker sidecar, shared socket/workspace volumes, and runtime-specific privilege settings.

Agents receive a long termination grace period and use the agent's first-SIGTERM graceful drain behavior. KEDA/HPA chooses scale-in victims, so the configured maximum is a desired-replica bound rather than a hard bound on live terminating Pods.

### Autoscaling

Render a KEDA `TriggerAuthentication` and `ScaledObject` targeting the runner Deployment. Two `metrics-api` triggers read the queue's `scheduled` and `running` values from `https://agent.buildkite.com/v3/metrics`; a scaling modifier sums them with target `1`. Default to `minReplicaCount: 1`, a 10-second poll, 60-second zero cooldown, and a 30-second scale-down stabilization window.

Direct-token mode creates one Secret containing the raw agent token and `Authorization: Token <token>` value. Existing-secret mode accepts separate agent and metrics Secret references because Helm cannot derive the prefixed authorization value from an existing Secret.

### Shared KEDA prerequisite

Do not bundle KEDA or its cluster-scoped resources. Use Helm API capabilities to fail with a clear prerequisite error when either required KEDA kind is unavailable. A separate KEDA installation remains available to reconcile finalizers when any runner release is uninstalled and can serve multiple runner namespaces.

### Verification

- `make test-helm` validates missing API failures, standard, Kata, Sysbox, direct-token, existing-secret, disabled, and rejected-input renders, then lints the chart.
- `make test-helm-e2e` first verifies the chart rejects a cluster without KEDA, installs KEDA separately, installs two runner releases, then confirms one runner release can be uninstalled without disrupting the other release or KEDA.
- Existing repository lint, generation, and unit checks remain green.
