# RunnerPool autoscaling & graceful idle termination

## Goal

Allow a `RunnerPool` to autoscale up to a maximum number of agent pods, and
gracefully terminate agents that have been idle for a period of time without
interrupting any running job (no data loss).

## Scaling model: warm idle buffer

Rather than scaling on Buildkite queue depth, the operator scales on the pool's
own busy/idle state:

- `minIdleRunners` — the number of idle (ready, not running a job) agents to keep warm.
- If fewer than `minIdleRunners` agents are idle, create pods (up to `maxRunners`).
- If more than `minIdleRunners` agents are idle, gracefully terminate the surplus.

Each reconcile:

```
busy          = count of pods reporting aggregate_status == "busy"
confirmedIdle = count of ready pods reporting aggregate_status == "idle"
unknown       = warming, unreachable, or unready pods
total         = busy + confirmedIdle + unknown
desiredTotal  = min(busy + minIdleRunners, maxRunners)
```

- If `total < desiredTotal` → create `desiredTotal - total` pods.
- Else if `total > desiredTotal` → terminate up to
  `confirmedIdle - minIdleRunners` pods observed idle for at least
  `idleTimeoutSeconds`, re-confirming idle immediately before deletion.

Unknown pods count toward the total so an unreachable health endpoint cannot
cause an unbounded scale-up, but they are never scale-down candidates and never
consume the confirmed-idle floor.

`minIdleRunners` is the only floor, so **scale-to-zero happens when
`minIdleRunners = 0`**. Because there is no queue-depth signal, a pool at zero
remains dormant until `minIdleRunners` is increased. One scale direction is applied per reconcile;
`RequeueAfter` drives convergence.

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

The endpoint is available in Buildkite agent v3.72.0 and newer. Compatible
custom images must provide the same endpoint and graceful SIGTERM behavior.
Readiness uses the health server's `/agent/1` heartbeat endpoint.

Idle duration is observational rather than mathematically continuous: a short
job entirely between polls can be missed. Any observed busy state or failed
status check clears `buildkite.com/idle-since`; immediate re-confirmation plus
graceful SIGTERM protects a job even when its busy interval was not sampled.

Considered and rejected: OTEL spans (push-based, sampled, needs a collector,
laggy), Prometheus `/metrics` (coarser), and polling Buildkite's central API
(rate-limited, not per-pod-cheap).

## Pod management: operator-managed pods (no Deployment)

The current single `Deployment` is replaced with pods the operator creates and
deletes directly. A Deployment cannot reliably terminate a *specific* idle pod on
scale-down (the ReplicaSet controller picks victims; `pod-deletion-cost` is only
best-effort and races with job pickup). Managing pods directly lets the operator
select a confirmed-idle pod and delete exactly it.

Because most Pod template fields are immutable, each Pod carries a hash of its
desired template. Changes to image, queue, token reference, resources, or
termination grace roll through stale Pods without deleting a busy agent. The
controller surges by one when below `maxRunners`; at the hard cap it deletes one
confirmed-idle stale Pod first, briefly allowing the pool to fall below
`minIdleRunners`, then creates its replacement on the next reconcile.

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
- `maxRunners int32` — required, `Minimum=1`. Hard cap on total pods.
- `minIdleRunners *int32` — optional, default `1`, `Minimum=0`. Warm idle buffer
  / floor. The pointer preserves an explicit zero through Go client updates.
- `idleTimeoutSeconds *int32` — optional, default `10`, `Minimum=0`. Observed
  idle duration before a pod is eligible for termination. The pointer preserves
  an explicit zero through Go client updates.
- `terminationGracePeriodSeconds *int64` — optional, default `3600`, `Minimum=1`.
- CEL cross-field validation: `minIdleRunners <= maxRunners`.

Status: keep `conditions`, `observedGeneration`; add `totalRunners`,
`idleRunners`, `busyRunners`, `readyRunners`. `idleRunners` counts only ready,
confirmed-idle Pods, so unknown Pods are the difference between total and
confirmed busy/idle counts. `Ready=True` when the desired total is present, all
active Pods are Kubernetes Ready, and no template rollout is pending; an
intentional zero-Pod pool is Ready. Printcolumns: `Max`, `Idle`, `Busy`, `Total`,
`Age`.

This is a breaking change, accepted at `v1alpha1`.

There is no in-place migration from the earlier Deployment-based prototype.
Existing RunnerPools must be deleted and recreated during upgrade so legacy
Deployments cannot continue running alongside directly managed Pods.

## Controller changes (`internal/controller/runnerpool_controller.go`)

Reconcile flow:
1. Fetch `RunnerPool` (NotFound → nothing to do; cascade GC handles pods).
2. List owned pods (label selector + owner ref), excluding terminating ones;
   remove terminal pods so they can be replaced.
3. Query each pod's `/status.json`:
   - busy → clear `buildkite.com/idle-since` annotation, count busy.
   - ready + idle → set `buildkite.com/idle-since` to now if absent; eligible
     for eviction when `now - idleSince >= idleTimeoutSeconds`.
   - unreachable, unready, or no pod IP → clear idle-since, count as unknown.
4. Compute `busy`, `confirmedIdle`, `unknown`, `total`, `desiredTotal`.
5. Scale up: create pods (`generateName: <pool>-agent-`) up to `desiredTotal`.
6. Scale down: else terminate up to `confirmedIdle - minIdleRunners`
   eviction-eligible pods, re-confirming idle via `/status.json` immediately
   before deletion.
7. If the total is otherwise correct, roll stale Pod templates using the
   bounded surge/delete behavior above.
8. Update status; `RequeueAfter` a ~10s poll interval, shortened to a positive
   `idleTimeoutSeconds` when smaller.

Pod template (`agent` container):
- Image/resources from spec (reuse existing defaulting helpers).
- Env: `BUILDKITE_AGENT_TOKEN`, `BUILDKITE_AGENT_TAGS=queue=<queue>`, and
  `BUILDKITE_AGENT_HEALTH_CHECK_ADDR=0.0.0.0:<healthPort>` (new constant).
- `terminationGracePeriodSeconds` from spec; `health` container port + readiness
  probe on `/agent/1`; no `--kubernetes-exec`; owner reference and desired
  template hash set.

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

- Update `config/samples/v1alpha1_runnerpool.yaml` to `maxRunners`,
  `minIdleRunners`, `idleTimeoutSeconds`.
- Rewrite `internal/controller/runnerpool_controller_test.go` (Ginkgo) with the
  fake status checker: scale up to buffer, never below `minIdleRunners`, cap at
  `maxRunners`, evict only after `idleTimeoutSeconds`, never evict busy, scale to
  zero when `minIdleRunners = 0`, distinguish unknown Pods, replace terminal Pods, and
  roll template changes without interrupting busy agents.
- Update `test/e2e/e2e_test.go` for pod-based ownership/cascade.

## Generated artifacts (run after code edits)

```
make manifests   # CRD + RBAC from markers
make generate    # deepcopy for new pointer fields
make lint-fix
make test
make helm        # generated installer and Helm chart
```

## Assumptions

- The in-cluster manager reaches pods over their pod IPs on the health port
  (no NetworkPolicy assumed).
- Simple in-container agent model (jobs run in the agent container).
