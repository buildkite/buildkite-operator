# Standalone Buildkite runner chart

## Summary

Add a new, hand-maintained Helm chart to the repository from a branch based on `main`. The chart installs the Buildkite operator and one autoscaling `RunnerPool` as a single customer-facing unit, while research branches remain reference material rather than implementation ancestry or generated chart sources.

## Requirements

- Author the chart independently under `charts/buildkite-operator`; do not import or regenerate `dist/chart` from `allan/eks-learning-runnerpool`.
- Integrate the minimum `RunnerPool` API and controller implementation needed by the chart into the codebase on top of `main`.
- A single Helm installation must provide the CRD, operator Deployment and RBAC, agent credential Secret, and one `RunnerPool`.
- Keep one idle agent by default and scale up as agents become busy, bounded by a customer-supplied positive maximum.
- Require a Buildkite queue and either a token value or existing Secret reference.
- Install CRDs through Helm's `crds/` directory so first installation can create a `RunnerPool` in the same release and uninstall retains the CRD.
- Have no chart dependencies. Do not install or require KEDA, Cluster Autoscaler, cert-manager, or Prometheus Operator.
- Keep AWS/EKS lab resources, observations, credentials metadata, and retired-environment configuration out of the chart.
- Allow operator-only installation by disabling the chart-managed `RunnerPool`.
- Verify direct-token, existing-Secret, operator-only, invalid-input, first-install, reconciliation, and uninstall behavior.

## Context

- `main` contains Kubebuilder manager scaffolding but no custom API or controller.
- `allan/eks-learning-runnerpool` demonstrates the desired warm-buffer behavior and contains API/controller code that can be selectively integrated. Its generated `dist/chart` and EKS/KEDA samples are not part of this implementation.
- The controller's warm-buffer policy scales from one without queue-depth APIs. This meets the agreed product requirement; scale-from-zero is not required.
- The chart is a separate maintained distribution artifact, not a Kubebuilder Helm-plugin output. Its values and templates therefore remain stable when operator manifests are regenerated.

## Implementation

### Operator capability

Integrate the `RunnerPool` API, direct agent-Pod reconciliation, status polling, manager registration, RBAC markers, and focused tests from the research implementation into `api/v1alpha1`, `internal/controller`, and `cmd/main.go`. Regenerate CRDs, RBAC, and deepcopy code using the repository's standard commands.

Do not bring across EKS/KEDA samples, experiment records, generated Helm output, or branch-specific deployment scripts.

### Independent chart

Create `charts/buildkite-operator` with:

- `Chart.yaml`, `.helmignore`, `values.yaml`, and `values.schema.json`;
- `crds/runnerpools.buildkite.com.yaml` sourced from the generated CRD;
- templates for the manager Deployment, service account, cluster-scoped RBAC, optional metrics Service, token Secret, and `RunnerPool`;
- shared naming and label helpers; and
- customer-facing installation notes.

The chart values must expose manager image configuration, `runnerPool.enabled`, queue, maximum runners, minimum idle runners defaulting to `1`, idle timeout, termination grace period, agent image/resources, and direct-token or existing-Secret credential modes. Reject missing and conflicting inputs during rendering.

### Documentation and tooling

Document a complete installation using both credential modes, the one-warm-agent scaling policy, image publication requirement, scale-from-zero limitation, and retained-CRD behavior. Add focused chart lint/render checks and Make targets without coupling chart maintenance to Kubebuilder's Helm plugin.

### End-to-end verification

Use the isolated Kind suite to install the new chart with the locally built manager image, a fake token, and a pause agent image. Verify that the chart installs the CRD first, starts the manager, creates the Secret and `RunnerPool`, reconciles one owned agent Pod with the configured queue, and removes release-owned resources on uninstall while retaining the CRD.

## Implementation order

1. Integrate and verify the minimum `RunnerPool` API/controller capability on top of `main`.
2. Generate the CRD/RBAC/deepcopy artifacts.
3. Author the independent chart under `charts/buildkite-operator`.
4. Add chart render/lint checks and documentation.
5. Exercise installation and uninstall in the isolated Kind suite.
6. Run regeneration drift checks, lint, unit tests, chart tests, and end-to-end tests.
