# RunnerPool autoscaling & graceful idle termination

## Goal

Allow a `RunnerPool` to autoscale up to a maximum number of agent pods, and
gracefully terminate agents that have been idle for a period of time without
interrupting any running job (no data loss).

## Scaling model: warm idle buffer

Rather than scaling on Buildkite queue depth, the operator scales on the pool's
own busy/idle state:

- `minIdle` — the number of idle (ready, not running a job) agents to keep warm.
- If fewer than `minIdle` agents are idle, create pods (up to `maxReplicas`).
- If more than `minIdle` agents are idle, gracefully terminate the surplus.

Each reconcile:

```
busy         = count of pods reporting aggregate_status == "busy"
total        = count of non-terminating owned pods
idle         = total - busy                      # includes warming pods
desiredTotal = min(busy + minIdle, maxReplicas)
```

- If `total < desiredTotal` → create `desiredTotal - total` pods.
- Else if `idle > minIdle` → terminate up to `idle - minIdle` pods that have been
  continuously idle for at least `idleTimeoutSeconds`, re-confirming idle
  immediately before deletion.

`minIdle` is the only floor, so **scale-to-zero happens when `minIdle = 0`**.
One scale direction is applied per reconcile; `RequeueAfter` drives convergence.

## Busy/idle detection: agent `/status.json`

The buildkite-agent exposes a local HTTP status server when started with
`BUILDKITE_AGENT_HEALTH_CHECK_ADDR` (disabled by default). `GET /status.json`
returns machine-readable state:

```json
{
  "health": "ok",
  "aggregate_status": "busy",
  "workers": [
    {"status": "busy", "current_job_id": "0192-uuid", "id": "agent-uuid", "spawn_index": 0}
  ]
}
```

This reflects the agent's `setBusy()`/`setIdle()` state machine, which flips
synchronously around every job. The operator polls each pod at
`http://<pod-ip>:<healthPort>/status.json` and treats `aggregate_status == "idle"`
as safe-to-evict. No Buildkite API/metrics token is required — state comes from
the pods, not Buildkite's backend.

Considered and rejected: OTEL spans (push-based, sampled, needs a collector,
laggy), Prometheus `/metrics` (coarser), and polling Buildkite's central API
(rate-limited, not per-pod-cheap).

## Pod management: operator-managed pods (no Deployment)

The current single `Deployment` is replaced with pods the operator creates and
deletes directly. A Deployment cannot reliably terminate a *specific* idle pod on
scale-down (the ReplicaSet controller picks victims; `pod-deletion-cost` is only
best-effort and races with job pickup). Managing pods directly lets the operator
select a confirmed-idle pod and delete exactly it.

## Graceful termination: no data loss

Agents run in the simple in-container model (no `--kubernetes-exec`). In that
model the **first SIGTERM triggers a graceful stop**: the agent stops accepting
new work, finishes its current job, then exits. This closes the only race in the
design — if a pod picks up a job between the operator confirming it idle and the
SIGTERM landing, the job still completes.

A generous, configurable `terminationGracePeriodSeconds` (default 3600) is the
backstop that lets a rare in-flight job finish before the pod is force-killed.
Confirmed-idle pods have no job and terminate promptly.

Pool deletion uses the owner-reference cascade: deleting a `RunnerPool` deletes
its pods, each of which drains gracefully within its grace period. No finalizer.

## API changes (`api/v1alpha1/runnerpool_types.go`)

Remove:
- `spec.replicas` field.
- `+kubebuilder:subresource:scale` marker.
- `Desired` printcolumn.

Add flat, top-level spec fields:
- `maxReplicas int32` — required, `Minimum=1`. Hard cap on total pods.
- `minIdle int32` — optional, default `1`, `Minimum=0`. Warm idle buffer / floor.
- `idleTimeoutSeconds int32` — optional, default `10`, `Minimum=0`. Continuous
  idle duration before a pod is eligible for termination.
- `terminationGracePeriodSeconds *int64` — optional, default `3600`, `Minimum=1`.
- CEL cross-field validation: `minIdle <= maxReplicas`.

Status: keep `conditions`, `observedGeneration`; add `totalReplicas`,
`idleReplicas`, `busyReplicas`, `readyReplicas`. Printcolumns: `Max`, `Idle`,
`Busy`, `Total`, `Age`.

This is a breaking change, accepted at `v1alpha1`.

## Controller changes (`internal/controller/runnerpool_controller.go`)

Reconcile flow:
1. Fetch `RunnerPool` (NotFound → nothing to do; cascade GC handles pods).
2. List owned pods (label selector + owner ref), excluding terminating ones.
3. Query each pod's `/status.json`:
   - busy → clear `buildkite.com/idle-since` annotation, count busy.
   - idle → set `buildkite.com/idle-since` to now if absent; eligible for
     eviction when `now - idleSince >= idleTimeoutSeconds`.
   - unreachable / no pod IP (warming) → counts toward total, not evictable.
4. Compute `busy`, `total`, `idle`, `desiredTotal`.
5. Scale up: create pods (`generateName: <pool>-agent-`) up to `desiredTotal`.
6. Scale down: else terminate up to `idle - minIdle` eviction-eligible pods,
   re-confirming idle via `/status.json` immediately before deletion.
7. Update status; `RequeueAfter` a poll interval (~10s, `<= idleTimeoutSeconds`).

Pod template (`agent` container):
- Image/resources from spec (reuse existing defaulting helpers).
- Env: `BUILDKITE_AGENT_TOKEN`, `BUILDKITE_AGENT_TAGS=queue=<queue>`, and
  `BUILDKITE_AGENT_HEALTH_CHECK_ADDR=0.0.0.0:<healthPort>` (new constant).
- `terminationGracePeriodSeconds` from spec; `health` container port + readiness
  probe on the health server; no `--kubernetes-exec`; owner reference set.

Testability: introduce an `AgentStatusChecker` interface
(`Check(ctx, podIP, port) (AgentStatus, error)`) as a reconciler field; default
HTTP implementation, fake injected in unit tests. Idle-since is stored as a pod
annotation so it survives operator restarts and is test-manipulable.

Watches: `For(&RunnerPool{}).Owns(&corev1.Pod{})`.

## RBAC

Replace the `apps/deployments` grant with `core/pods`
(`get;list;watch;create;update;patch;delete`). Keep runnerpools + status +
finalizers/events grants.

## Wiring (`cmd/main.go`)

Set the reconciler's `StatusChecker` (HTTP default), poll interval, and HTTP
client/timeout.

## Samples & tests

- Update `config/samples/v1alpha1_runnerpool.yaml` to `maxReplicas`, `minIdle`,
  `idleTimeoutSeconds`.
- Rewrite `internal/controller/runnerpool_controller_test.go` (Ginkgo) with the
  fake status checker: scale up to buffer, never below `minIdle`, cap at
  `maxReplicas`, evict only after `idleTimeoutSeconds`, never evict busy, scale to
  zero when `minIdle = 0`.
- Update `test/e2e/e2e_test.go` for pod-based ownership/cascade.

## Generated artifacts (run after code edits)

```
make manifests   # CRD + RBAC from markers
make generate    # deepcopy for new *int64 field
make lint-fix
make test
```

## Assumptions

- The in-cluster manager reaches pods over their pod IPs on the health port
  (no NetworkPolicy assumed).
- Simple in-container agent model (jobs run in the agent container).
