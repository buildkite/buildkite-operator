#!/usr/bin/env bash
# Sourced by test-helm-e2e.sh instead of its OCI accelerator-specific section.
# Fill node containerd on a miss, using the accelerator test's Docker commands.

image=public.ecr.aws/docker/library/alpine:3.20
"${KUBECTL[@]}" create namespace "${ACCEL_NAMESPACE}"
"${HELM_CLUSTER[@]}" install spegel oci://ghcr.io/spegel-org/helm-charts/spegel \
	--version 0.7.4 --namespace "${ACCEL_NAMESPACE}" \
	--set spegel.containerdMirrorAdd=false --set spegel.logLevel=DEBUG
"${KUBECTL[@]}" rollout status daemonset/spegel -n "${ACCEL_NAMESPACE}" --timeout=3m

spegel_dir=$(mktemp -d)
# Build for the Docker host's architecture, which may differ from the local Go host.
case "$(docker exec "${KIND_CLUSTER}-control-plane" uname -m)" in
	x86_64) puller_arch=amd64 ;;
	aarch64) puller_arch=arm64 ;;
	*) echo "Unsupported Kind node architecture" >&2; exit 1 ;;
esac
CGO_ENABLED=0 GOOS=linux GOARCH="${puller_arch}" go build -o "${spegel_dir}/spegel-puller" ./hack/spegel-puller
spegel_puller_image="${KIND_CLUSTER}-spegel-puller:local"
docker build -f hack/spegel-puller/Dockerfile -t "${spegel_puller_image}" "${spegel_dir}"
"${KIND:-kind}" load docker-image "${spegel_puller_image}" --name "${KIND_CLUSTER}"
umask 077
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=public.ecr.aws \
	-addext subjectAltName=DNS:public.ecr.aws \
	-keyout "${spegel_dir}/tls.key" -out "${spegel_dir}/tls.crt" >"${spegel_dir}/certificate.log" 2>&1
"${KUBECTL[@]}" create secret tls spegel-bridge-tls -n "${ACCEL_NAMESPACE}" \
	--cert="${spegel_dir}/tls.crt" --key="${spegel_dir}/tls.key"
dns_ip=$("${KUBECTL[@]}" get service kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}')
sed -e "s/@DNS@/${dns_ip}/g" \
	-e "s/@SPEGEL_HOST@/spegel-registry.${ACCEL_NAMESPACE}.svc.cluster.local/g" \
	hack/spegel-registry-nginx.conf >"${spegel_dir}/nginx.conf"
"${KUBECTL[@]}" create configmap spegel-bridge-config -n "${ACCEL_NAMESPACE}" --from-file="${spegel_dir}/nginx.conf"
"${KUBECTL[@]}" apply -n "${ACCEL_NAMESPACE}" -f - <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: spegel-puller
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: spegel-puller
rules:
  - apiGroups: [""]
    resources: [pods]
    verbs: [create, get]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: spegel-puller
subjects:
  - kind: ServiceAccount
    name: spegel-puller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: spegel-puller
---
apiVersion: v1
kind: Service
metadata:
  name: spegel-bridge
spec:
  selector: {app: spegel-bridge}
  ports:
    - {name: https, port: 443, targetPort: 8443}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spegel-bridge
spec:
  replicas: 1
  selector:
    matchLabels: {app: spegel-bridge}
  template:
    metadata:
      labels: {app: spegel-bridge}
    spec:
      serviceAccountName: spegel-puller
      automountServiceAccountToken: false
      containers:
        - name: nginx
          image: nginx:1.29-alpine
          ports:
            - {name: https, containerPort: 8443}
          readinessProbe:
            tcpSocket: {port: https}
          resources:
            requests: {cpu: 50m, memory: 32Mi}
          volumeMounts:
            - {name: config, mountPath: /etc/nginx/nginx.conf, subPath: nginx.conf, readOnly: true}
            - {name: tls, mountPath: /etc/nginx/tls, readOnly: true}
        - name: puller
          image: "${spegel_puller_image}"
          imagePullPolicy: Never
          env:
            - {name: WARM_IMAGE, value: "${image}"}
            - {name: WARM_NODE, value: "${KIND_CLUSTER}-control-plane"}
            - {name: SPEGEL_REGISTRY, value: "http://spegel-registry:5000"}
          readinessProbe:
            httpGet: {path: /healthz, port: 8080}
          resources:
            requests: {cpu: 50m, memory: 32Mi}
          volumeMounts:
            - {name: api-access, mountPath: /var/run/secrets/kubernetes.io/serviceaccount, readOnly: true}
      volumes:
        - name: api-access
          projected:
            sources:
              - serviceAccountToken: {path: token, expirationSeconds: 3600}
              - configMap:
                  name: kube-root-ca.crt
                  items: [{key: ca.crt, path: ca.crt}]
              - downwardAPI:
                  items:
                    - path: namespace
                      fieldRef: {fieldPath: metadata.namespace}
        - name: config
          configMap: {name: spegel-bridge-config}
        - name: tls
          secret: {secretName: spegel-bridge-tls}
YAML
if ! "${KUBECTL[@]}" rollout status deployment/spegel-bridge -n "${ACCEL_NAMESPACE}" --timeout=2m; then
	"${KUBECTL[@]}" logs deployment/spegel-bridge -n "${ACCEL_NAMESPACE}" --all-containers >&2 || true
	exit 1
fi
bridge_ip=$("${KUBECTL[@]}" get service spegel-bridge -n "${ACCEL_NAMESPACE}" -o jsonpath='{.spec.clusterIP}')

install_runner_chart "${ACCEL_RELEASE}" "${ACCEL_NAMESPACE}" accel -- \
	--set-string defaults.docker.resources.requests.cpu=100m \
	--set-string defaults.docker.resources.requests.memory=256Mi \
	--set-string defaults.docker.resources.requests.ephemeral-storage=1Gi \
	--set-string queues.accel.runtime=dind \
	--set ociAccelerator.enabled=false
# Only this test runner resolves ECR to the stateless bridge. The bridge itself
# resolves the real upstream. Mount only the public certificate in the runner.
"${KUBECTL[@]}" patch deployment "${ACCEL_RELEASE}-accel" -n "${ACCEL_NAMESPACE}" --patch "{
  \"spec\": {\"template\": {\"metadata\": {\"labels\": {\"experiments.buildkite.com/spegel-test\": \"true\"}}, \"spec\": {
    \"hostAliases\": [{\"ip\": \"${bridge_ip}\", \"hostnames\": [\"public.ecr.aws\"]}],
    \"volumes\": [{\"name\": \"spegel-ca\", \"secret\": {
      \"secretName\": \"spegel-bridge-tls\", \"items\": [{\"key\": \"tls.crt\", \"path\": \"ca.crt\"}]
    }}],
    \"initContainers\": [{\"name\": \"dockerd\",
      \"env\": [{\"name\": \"SSL_CERT_DIR\", \"value\": \"/etc/ssl/certs:/etc/spegel-ca\"}],
      \"volumeMounts\": [{\"name\": \"spegel-ca\", \"mountPath\": \"/etc/spegel-ca\", \"readOnly\": true}]
    }]
  }}}
}"
dockerd_pod=""
for _ in $(seq 1 180); do
	dockerd_pod=$("${KUBECTL[@]}" get pods -n "${ACCEL_NAMESPACE}" -l app.kubernetes.io/component=runner,experiments.buildkite.com/spegel-test=true \
		-o jsonpath='{range .items[?(@.status.initContainerStatuses[0].ready==true)]}{.metadata.name}{end}')
	[[ -n "${dockerd_pod}" ]] && break
	sleep 1
done
if [[ -z "${dockerd_pod}" ]]; then
	echo "Runner Docker daemon did not start" >&2
	"${KUBECTL[@]}" describe pods -n "${ACCEL_NAMESPACE}" -l experiments.buildkite.com/spegel-test=true >&2
	exit 1
fi
dockerd() { "${KUBECTL[@]}" exec -n "${ACCEL_NAMESPACE}" "${dockerd_pod}" -c dockerd -- "$@"; }

# Neither node nor a fill Pod may contain the test image before the first pull.
for node in "${KIND_CLUSTER}-control-plane" "${KIND_CLUSTER}-worker"; do
	if docker exec "${node}" ctr --namespace k8s.io images list -q | grep -Fx "${image}" >/dev/null; then
		echo "Test image was already present on ${node}" >&2
		exit 1
	fi
done
[[ -z "$("${KUBECTL[@]}" get pods -n "${ACCEL_NAMESPACE}" -l app=spegel-fill -o name)" ]]

spegel_blob_hits() {
	awk '/"registry":"public.ecr.aws"/ && /"handler":"blob"/ && /"status":200/ { n++ } END { print n+0 }'
}

# Keep the existing accelerator test's image name and Docker commands.
dockerd docker pull -q "${image}"
puller_logs=$("${KUBECTL[@]}" logs deployment/spegel-bridge -n "${ACCEL_NAMESPACE}" -c puller)
if ! grep '"event":"fill_started"' <<<"${puller_logs}" >/dev/null || \
	! grep '"event":"fill_ready"' <<<"${puller_logs}" >/dev/null; then
	echo "First pull did not complete a waiting cache fill" >&2
	echo "${puller_logs}" >&2
	"${KUBECTL[@]}" logs deployment/spegel-bridge -n "${ACCEL_NAMESPACE}" -c nginx >&2
	"${KUBECTL[@]}" describe pods -n "${ACCEL_NAMESPACE}" -l app=spegel-fill >&2
	exit 1
fi
echo "PASS: the first pull populated an empty node cache before completing"
dockerd docker image rm "${image}" >/dev/null
hits_before=$("${KUBECTL[@]}" logs -n "${ACCEL_NAMESPACE}" -l app.kubernetes.io/name=spegel -c registry --tail=-1 | spegel_blob_hits)
dockerd docker pull -q "${image}"
spegel_logs=$("${KUBECTL[@]}" logs -n "${ACCEL_NAMESPACE}" -l app.kubernetes.io/name=spegel -c registry --tail=-1)
hits_after=$(spegel_blob_hits <<<"${spegel_logs}")
puller_logs=$("${KUBECTL[@]}" logs deployment/spegel-bridge -n "${ACCEL_NAMESPACE}" -c puller)
fill_count=$(awk '/"event":"fill_started"/ { n++ } END { print n+0 }' <<<"${puller_logs}")
if [[ "${hits_after}" -le "${hits_before}" || "${fill_count}" -ne 1 ]]; then
	echo "Second pull did not reuse Spegel content from a single cache fill" >&2
	echo "${spegel_logs}" >&2
	echo "${puller_logs}" >&2
	"${KUBECTL[@]}" logs deployment/spegel-bridge -n "${ACCEL_NAMESPACE}" -c nginx --tail=40 >&2
	exit 1
fi
echo "PASS: the second pull received Spegel blobs (${hits_before} -> ${hits_after} hits) without another fill"

"${HELM_CLUSTER[@]}" uninstall "${ACCEL_RELEASE}" --namespace "${ACCEL_NAMESPACE}" --wait --timeout=2m
"${HELM_CLUSTER[@]}" uninstall spegel --namespace "${ACCEL_NAMESPACE}" --wait --timeout=2m
"${KUBECTL[@]}" delete deployment/spegel-bridge service/spegel-bridge -n "${ACCEL_NAMESPACE}"
