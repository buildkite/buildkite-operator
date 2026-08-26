# Garage-backed Buildkite agent cache

## Problem

`RunnerPool` directly owns and autoscales Buildkite agent Pods, but pools cannot
opt into an operator-managed object store for the Buildkite agent cache feature.

Buildkite agent 3.128.0 and newer can use an agent-managed S3 cache store with:

- `BUILDKITE_AGENT_CACHE_STORE_URL`
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

The agent uploads content-addressed objects and refreshes an object's
`LastModified` timestamp when restoring it. It does not delete objects, so the
store must apply a lifecycle rule or its persistent volume will grow without
bound.

Implementation starts from `origin/prototype-cas` at `3c37a2f`.

## Proposed API

Add a namespaced `CacheStore` resource in `buildkite.com/v1alpha1`. One store
can be referenced by multiple `RunnerPool` resources in the same namespace.

```yaml
apiVersion: buildkite.com/v1alpha1
kind: CacheStore
metadata:
  name: build-cache
spec:
  image: dxflrs/garage:v2.3.0
  bucket: buildkite-cache
  rpcSecretRef:
    name: build-cache-rpc
    key: rpc-secret
  credentialsSecretRef:
    name: build-cache-credentials
    accessKeyIDKey: access-key-id
    secretAccessKeyKey: secret-access-key
  storage:
    size: 20Gi
    storageClassName: standard
  retentionDays: 2
  resources: {}
```

The API contract is:

- `image` defaults to the pinned Garage `dxflrs/garage:v2.3.0` image and can be
  overridden for private mirrors.
- `bucket` defaults to `buildkite-cache` and is immutable. Validate it as an S3
  bucket name.
- `rpcSecretRef` selects Garage's 64-character hexadecimal RPC secret.
- `credentialsSecretRef` selects the S3 access-key ID and secret key used both
  by Garage's default-bucket bootstrap and by cache clients.
- Both referenced Secrets must have `immutable: true`. Validate their presence
  and Garage's value constraints during reconciliation: access-key IDs are at
  least eight allowed characters, and secret keys are at least 16 printable
  ASCII characters.
- `storage.size` is required; `storage.storageClassName` is optional. Both are
  immutable in v1alpha1. The controller uses one `ReadWriteOnce` claim.
- `retentionDays` defaults to `2` and has a minimum of one. Garage applies
  lifecycle expiry on day boundaries, so two days gives approximately 24–48
  hours of retention while Buildkite's restore-time self-copy keeps hot objects
  alive.
- `resources` configures the Garage container's compute resources.
- Expose an override for the lifecycle Job image, while defaulting it to a
  version-pinned official AWS CLI image selected and verified during
  implementation. Never use a floating `latest` tag.

Secret references, bucket, and storage are immutable because Garage cannot
rotate an existing key's secret and StatefulSet claim templates cannot be
updated safely in place. Image, resources, lifecycle image, and retention are
mutable.

`CacheStoreStatus` contains `observedGeneration` and a standard `Ready`
condition. Reasons distinguish invalid or missing Secrets, a pending
StatefulSet, lifecycle configuration, and an available store. The status does
not duplicate deterministic connection details.

Extend `RunnerPoolSpec` with an optional, same-namespace reference:

```yaml
spec:
  image: buildkite/agent:3.128.0
  cacheStoreRef:
    name: build-cache
```

Add a `CacheStoreReady` condition to `RunnerPool`. Keep its existing `Ready`
condition scoped to agent Pod availability.

## CacheStore reconciliation

Scaffold `CacheStore` and its controller with `kubebuilder create api` so the
project metadata, RBAC helpers, samples, and scaffold markers remain valid.
Customize the generated files rather than creating the API scaffolding by hand.

The controller owns these resources:

1. A ConfigMap containing Garage's TOML configuration.
2. A headless Service for the StatefulSet's stable RPC identity.
3. A ClusterIP Service exposing only the S3 API on port 3900.
4. A one-replica StatefulSet.
5. A short-lived Job that applies the bucket lifecycle configuration through
   the S3 API.

The Garage configuration uses:

- `replication_factor = 1`
- `db_engine = "sqlite"`
- metadata and object-data subdirectories on the same PVC
- region `garage`
- RPC port 3901, S3 port 3900, and admin/health port 3903
- the StatefulSet Pod's stable, fully qualified RPC DNS name

Run `/garage server --single-node --default-bucket`. Supply
`GARAGE_RPC_SECRET`, `GARAGE_DEFAULT_ACCESS_KEY`, and
`GARAGE_DEFAULT_SECRET_KEY` from the immutable Secrets and
`GARAGE_DEFAULT_BUCKET` from the spec. Garage synchronously creates the
single-node layout, key, and bucket before serving traffic.

The native bootstrap grants the key read, write, owner, and bucket-creation
permissions within this dedicated Garage instance. This broader permission set
is accepted for the initial implementation to avoid an additional Garage admin
API provisioning subsystem. Separate `CacheStore` instances do not share this
authority.

Use the upstream security posture: UID/GID 1000, `fsGroup: 1000`, non-root,
read-only root filesystem, runtime-default seccomp, no privilege escalation,
and all capabilities dropped. Disable service-account token mounting. Probe
the unauthenticated admin `/health` endpoint directly on the Pod; do not expose
the admin port through the client Service.

Set the StatefulSet PVC retention policy explicitly to `Retain` for deletion
and scaling. Deleting a `CacheStore` garbage-collects its ConfigMap, Services,
StatefulSet, and Jobs but leaves its PVC for deliberate manual recovery or
deletion. No finalizer is needed because the controller does not delete
external data.

The lifecycle Job waits for S3 readiness, then idempotently applies and verifies
a bucket lifecycle configuration with:

- object expiration after `retentionDays`
- incomplete multipart upload abortion after one day

The Job reads the same cache credentials Secret and reaches Garage through the
ClusterIP Service. Recreate the Job when its immutable template or desired
lifecycle hash changes. Delete superseded Jobs with foreground propagation and
wait for their Pods to stop before creating the replacement, so an old Job
cannot overwrite a newer lifecycle rule. `CacheStore` becomes Ready only when
the StatefulSet is ready and the current lifecycle Job has succeeded. Garage
runs lifecycle deletion daily, so expiration is not exact to the hour.

Watch referenced Secrets so creating a previously missing Secret or deleting a
Secret promptly updates status. Watch all owned resources so readiness and
drift reconcile without polling. Reconciliation must preserve API-server
defaults and server-assigned Service fields and avoid writes when desired state
is unchanged.

## RunnerPool integration

When `cacheStoreRef` resolves, inject these variables into the agent container:

```text
BUILDKITE_AGENT_CACHE_STORE_URL=s3://<bucket>?region=garage&endpoint=http://<store>.<namespace>.svc:3900&use_path_style=true
AWS_ACCESS_KEY_ID=<credentials Secret key reference>
AWS_SECRET_ACCESS_KEY=<credentials Secret key reference>
```

Construct and encode the URL with `net/url`; do not concatenate unescaped
query values. Do not inject the Garage RPC secret into agents.

The RunnerPool controller watches `CacheStore` resources and indexes pools by
their same-namespace reference so store readiness changes enqueue all sharing
pools. Reflect the store's state in `CacheStoreReady` without folding it into
agent Pod readiness.

If a referenced store exists, inject its deterministic configuration even
while it is starting; a temporary store outage must not scale down or otherwise
stop agents. Cache configuration contributes to the Pod template hash and rolls
only through confirmed-idle Pods using the existing safe rollout path. If the
reference is missing, report `CacheStoreNotFound`, create no new Pods, and leave
all existing Pods untouched. A new pool with an unresolved reference waits
rather than launching with silently missing cache settings. Removing
`cacheStoreRef` rolls the cache environment variables out through confirmed-idle
Pods. Store readiness changes alone do not alter the template hash.

Do not change the general `RunnerPool` image default. Document and demonstrate
that cache-enabled pools require `buildkite/agent:3.128.0` or newer. Admission
cannot reliably infer feature support from arbitrary image names.

## Scope and non-goals

- Garage v2.3 is the only managed backend in this API version.
- The store is persistent but single-node and non-HA. PVC snapshots, backup,
  restore, and multi-node Garage layouts are outside this change.
- Traffic is plaintext HTTP inside the cluster. TLS, Ingress, the Garage web
  interface, and NetworkPolicy generation are outside this change.
- The operator does not generate or rotate credentials. Reusing an access-key
  ID with a changed secret is unsupported by Garage; credential rotation
  remains a documented manual operation.
- PVC expansion and automatic PVC deletion are outside this change.
- Buildkite cluster cache-registry setup remains an external prerequisite. The
  registry must select an `agent_managed` store; the operator's existing agent
  token cannot configure that Buildkite-side setting.
- Cache save and restore remain pipeline actions. The operator only supplies
  the store and agent environment.
- Garage is AGPL-3.0 software distributed separately in its own container; note
  this clearly for deployers.

## Delivery slices

1. **API and generated artifacts**
   - Scaffold `CacheStore` in the existing `buildkite.com/v1alpha1` group.
   - Define validation, defaults, immutability, status, `cacheStoreRef`, and
     `CacheStoreReady`.
   - Regenerate deepcopy code, CRDs, RBAC helpers, samples, and register the new
     controller with the manager.

2. **Persistent Garage service**
   - Reconcile and own the ConfigMap, Services, and StatefulSet.
   - Validate immutable Secret contents, implement secure Pod settings and
     retained PVC behavior, and report status from StatefulSet readiness.
   - Cover idempotence, drift correction, missing/invalid Secrets, status
     transitions, and retained-claim configuration in envtest.

3. **Lifecycle and RunnerPool wiring**
   - Reconcile the lifecycle Job and gate store readiness on its success.
   - Inject the exact S3 URL and AWS credential references into agents.
   - Add CacheStore indexing/watches and `CacheStoreReady` propagation.
   - Cover shared stores, missing stores, startup/outage behavior, opt-out, and
     generated environment variables in controller tests.

4. **End-to-end and distribution**
   - Extend the isolated Kind test to create immutable test Secrets, a
     `CacheStore`, and a referencing `RunnerPool`.
   - Verify the StatefulSet, retained PVC policy, Services, lifecycle rule,
     `CacheStore` readiness, and the RunnerPool's `CacheStoreReady` condition.
   - Exercise authenticated S3 put, head, get, self-copy, and multipart upload
     operations against Garage, then verify a directly owned RunnerPool Pod
     contains the expected cache environment.
   - Update README and samples with the agent version requirement, Buildkite
     registry prerequisite, retention behavior, single-node limitation,
     credential contract, and manual PVC cleanup.
   - Regenerate the installer and Helm chart after API and RBAC changes.

## Verification

Run the repository-standard checks after implementation:

```bash
make manifests generate
make lint-fix
make test
make lint
make helm
make test-e2e
```

Run e2e only against its dedicated Kind cluster. Finish by confirming generated
artifacts are clean after rerunning generation and that the diff contains no
hand-edited generated files.
