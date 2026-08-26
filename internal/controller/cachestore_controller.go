// Copyright (c) 2026 Buildkite Pty Ltd
// SPDX-License-Identifier: MIT

package controller

import (
	"cmp"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"maps"
	"slices"
	"strings"

	appsv1 "k8s.io/api/apps/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/equality"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/intstr"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	buildkitecomv1alpha1 "github.com/buildkite/buildkite-operator/api/v1alpha1"
)

const (
	defaultGarageImage       = "dxflrs/garage:v2.3.0"
	defaultLifecycleImage    = "public.ecr.aws/aws-cli/aws-cli:2.27.41"
	defaultCacheBucket       = "buildkite-cache"
	defaultRetentionDays     = int32(2)
	garageRegion             = "garage"
	garageContainerName      = "garage"
	lifecycleContainerName   = "configure-lifecycle"
	garageDataVolumeName     = "data"
	garageConfigVolumeName   = "config"
	lifecycleTempVolumeName  = "tmp"
	lifecycleWorkingDir      = "/tmp"
	cacheStoreLabel          = "buildkite.com/cache-store"
	cacheStoreRPCSecretIndex = "spec.rpcSecretRef.name"
	cacheStoreCredsIndex     = "spec.credentialsSecretRef.name"
	lifecycleHashAnnotation  = "buildkite.com/lifecycle-hash"
	garageS3Port             = int32(3900)
	garageRPCPort            = int32(3901)
	garageAdminPort          = int32(3903)
)

// CacheStoreReconciler reconciles a CacheStore object.
type CacheStoreReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=buildkite.com,resources=cachestores,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=buildkite.com,resources=cachestores/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=buildkite.com,resources=cachestores/finalizers,verbs=update
// +kubebuilder:rbac:groups="",resources=secrets,verbs=get;list;watch
// +kubebuilder:rbac:groups="",resources=configmaps;services,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=apps,resources=statefulsets,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=batch,resources=jobs,verbs=get;list;watch;create;update;patch;delete

// Reconcile creates and observes the resources for a single-node Garage store.
func (r *CacheStoreReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := logf.FromContext(ctx)

	store := &buildkitecomv1alpha1.CacheStore{}
	if err := r.Get(ctx, req.NamespacedName, store); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	problem, err := r.validateReferencedSecrets(ctx, store)
	if err != nil {
		return ctrl.Result{}, err
	}
	if problem != nil {
		if err := r.reconcileStatus(ctx, store, *problem); err != nil {
			return ctrl.Result{}, fmt.Errorf("updating status of CacheStore %s: %w", store.Name, err)
		}
		return ctrl.Result{}, nil
	}

	configMap := &corev1.ConfigMap{ObjectMeta: metav1.ObjectMeta{Name: store.Name, Namespace: store.Namespace}}
	if err := r.createOrUpdate(ctx, store, configMap, func() error {
		configMap.Labels = withCacheStoreLabels(configMap.Labels, store)
		configMap.Data = map[string]string{"garage.toml": garageConfig(store)}
		return nil
	}); err != nil {
		return ctrl.Result{}, fmt.Errorf("reconciling ConfigMap %s: %w", configMap.Name, err)
	}

	rpcService := &corev1.Service{
		ObjectMeta: metav1.ObjectMeta{Name: garageRPCServiceName(store), Namespace: store.Namespace},
	}
	if err := r.createOrUpdate(ctx, store, rpcService, func() error {
		applyGarageRPCService(store, rpcService)
		return nil
	}); err != nil {
		return ctrl.Result{}, fmt.Errorf("reconciling RPC Service %s: %w", rpcService.Name, err)
	}

	s3Service := &corev1.Service{ObjectMeta: metav1.ObjectMeta{Name: store.Name, Namespace: store.Namespace}}
	if err := r.createOrUpdate(ctx, store, s3Service, func() error {
		applyGarageS3Service(store, s3Service)
		return nil
	}); err != nil {
		return ctrl.Result{}, fmt.Errorf("reconciling S3 Service %s: %w", s3Service.Name, err)
	}

	statefulSet := &appsv1.StatefulSet{ObjectMeta: metav1.ObjectMeta{Name: store.Name, Namespace: store.Namespace}}
	if err := r.createOrUpdate(ctx, store, statefulSet, func() error {
		applyGarageStatefulSet(store, statefulSet)
		return nil
	}); err != nil {
		return ctrl.Result{}, fmt.Errorf("reconciling StatefulSet %s: %w", statefulSet.Name, err)
	}

	lifecycleJob, err := r.reconcileLifecycleJob(ctx, store)
	if err != nil {
		return ctrl.Result{}, err
	}

	if err := r.reconcileStatus(ctx, store, cacheStoreReadyCondition(store, statefulSet, lifecycleJob)); err != nil {
		if apierrors.IsConflict(err) {
			return ctrl.Result{Requeue: true}, nil
		}
		return ctrl.Result{}, fmt.Errorf("updating status of CacheStore %s: %w", store.Name, err)
	}

	log.V(1).Info("Reconciled CacheStore", "cacheStore", store.Name)
	return ctrl.Result{}, nil
}

func (r *CacheStoreReconciler) createOrUpdate(
	ctx context.Context,
	store *buildkitecomv1alpha1.CacheStore,
	object client.Object,
	mutate controllerutil.MutateFn,
) error {
	op, err := controllerutil.CreateOrUpdate(ctx, r.Client, object, func() error {
		if err := mutate(); err != nil {
			return err
		}
		return ctrl.SetControllerReference(store, object, r.Scheme)
	})
	if err == nil && op != controllerutil.OperationResultNone {
		logf.FromContext(ctx).Info("Reconciled CacheStore resource",
			"cacheStore", store.Name, "resource", object.GetName(), "operation", op)
	}
	return err
}

func (r *CacheStoreReconciler) validateReferencedSecrets(
	ctx context.Context,
	store *buildkitecomv1alpha1.CacheStore,
) (*metav1.Condition, error) {
	rpcSecret := &corev1.Secret{}
	rpcKey := types.NamespacedName{Name: store.Spec.RPCSecretRef.Name, Namespace: store.Namespace}
	if err := r.Get(ctx, rpcKey, rpcSecret); err != nil {
		if apierrors.IsNotFound(err) {
			return cacheStoreProblem(store, "RPCSecretNotFound",
				fmt.Sprintf("RPC Secret %s was not found", rpcKey.Name)), nil
		}
		return nil, fmt.Errorf("getting RPC Secret %s: %w", rpcKey.Name, err)
	}
	if rpcSecret.Immutable == nil || !*rpcSecret.Immutable {
		return cacheStoreProblem(store, "RPCSecretInvalid",
			fmt.Sprintf("RPC Secret %s must be immutable", rpcSecret.Name)), nil
	}
	rpcValue, ok := rpcSecret.Data[store.Spec.RPCSecretRef.Key]
	if !ok {
		return cacheStoreProblem(store, "RPCSecretInvalid",
			fmt.Sprintf("RPC Secret %s does not contain key %s", rpcSecret.Name, store.Spec.RPCSecretRef.Key)), nil
	}
	decoded, decodeErr := hex.DecodeString(string(rpcValue))
	if decodeErr != nil || len(decoded) != 32 {
		return cacheStoreProblem(store, "RPCSecretInvalid",
			fmt.Sprintf("RPC Secret %s key %s must contain exactly 64 hexadecimal characters",
				rpcSecret.Name, store.Spec.RPCSecretRef.Key)), nil
	}

	credentials := &corev1.Secret{}
	credentialsKey := types.NamespacedName{Name: store.Spec.CredentialsSecretRef.Name, Namespace: store.Namespace}
	if err := r.Get(ctx, credentialsKey, credentials); err != nil {
		if apierrors.IsNotFound(err) {
			return cacheStoreProblem(store, "CredentialsSecretNotFound",
				fmt.Sprintf("credentials Secret %s was not found", credentialsKey.Name)), nil
		}
		return nil, fmt.Errorf("getting credentials Secret %s: %w", credentialsKey.Name, err)
	}
	if credentials.Immutable == nil || !*credentials.Immutable {
		return cacheStoreProblem(store, "CredentialsSecretInvalid",
			fmt.Sprintf("credentials Secret %s must be immutable", credentials.Name)), nil
	}
	accessKeyID, ok := credentials.Data[store.Spec.CredentialsSecretRef.AccessKeyIDKey]
	if !ok {
		return cacheStoreProblem(store, "CredentialsSecretInvalid",
			fmt.Sprintf("credentials Secret %s does not contain key %s",
				credentials.Name, store.Spec.CredentialsSecretRef.AccessKeyIDKey)), nil
	}
	if !validGarageAccessKeyID(accessKeyID) {
		return cacheStoreProblem(store, "CredentialsSecretInvalid",
			fmt.Sprintf("credentials Secret %s contains an invalid Garage access-key ID", credentials.Name)), nil
	}
	secretAccessKey, ok := credentials.Data[store.Spec.CredentialsSecretRef.SecretAccessKeyKey]
	if !ok {
		return cacheStoreProblem(store, "CredentialsSecretInvalid",
			fmt.Sprintf("credentials Secret %s does not contain key %s",
				credentials.Name, store.Spec.CredentialsSecretRef.SecretAccessKeyKey)), nil
	}
	if !validGarageSecretAccessKey(secretAccessKey) {
		return cacheStoreProblem(store, "CredentialsSecretInvalid",
			fmt.Sprintf("credentials Secret %s contains an invalid Garage secret access key", credentials.Name)), nil
	}

	return nil, nil
}

func validGarageAccessKeyID(value []byte) bool {
	if len(value) < 8 {
		return false
	}
	for _, c := range value {
		if (c < 'a' || c > 'z') && (c < 'A' || c > 'Z') &&
			(c < '0' || c > '9') && c != '-' && c != '_' && c != '.' {
			return false
		}
	}
	return true
}

func validGarageSecretAccessKey(value []byte) bool {
	if len(value) < 16 {
		return false
	}
	for _, c := range value {
		if c < 0x21 || c > 0x7e {
			return false
		}
	}
	return true
}

func cacheStoreProblem(store *buildkitecomv1alpha1.CacheStore, reason, message string) *metav1.Condition {
	return &metav1.Condition{
		Type:               buildkitecomv1alpha1.CacheStoreConditionReady,
		Status:             metav1.ConditionFalse,
		ObservedGeneration: store.Generation,
		Reason:             reason,
		Message:            message,
	}
}

func (r *CacheStoreReconciler) reconcileStatus(
	ctx context.Context,
	store *buildkitecomv1alpha1.CacheStore,
	condition metav1.Condition,
) error {
	updated := store.DeepCopy()
	updated.Status.ObservedGeneration = store.Generation
	meta.SetStatusCondition(&updated.Status.Conditions, condition)
	if equality.Semantic.DeepEqual(store.Status, updated.Status) {
		return nil
	}
	return r.Status().Update(ctx, updated)
}

func garageConfig(store *buildkitecomv1alpha1.CacheStore) string {
	return fmt.Sprintf(`metadata_dir = "/var/lib/garage/meta"
data_dir = "/var/lib/garage/data"
db_engine = "sqlite"
replication_factor = 1

rpc_bind_addr = "[::]:3901"
rpc_public_addr = "%s-0.%s.%s.svc.cluster.local:3901"

[s3_api]
s3_region = "garage"
api_bind_addr = "[::]:3900"

[admin]
api_bind_addr = "[::]:3903"
`, store.Name, garageRPCServiceName(store), store.Namespace)
}

func applyGarageRPCService(store *buildkitecomv1alpha1.CacheStore, service *corev1.Service) {
	service.Labels = withCacheStoreLabels(service.Labels, store)
	service.Spec.Type = corev1.ServiceTypeClusterIP
	service.Spec.ClusterIP = corev1.ClusterIPNone
	service.Spec.PublishNotReadyAddresses = true
	service.Spec.Selector = cacheStoreSelectorLabels(store)
	service.Spec.Ports = []corev1.ServicePort{{
		Name:       "rpc",
		Protocol:   corev1.ProtocolTCP,
		Port:       garageRPCPort,
		TargetPort: intstr.FromString("rpc"),
	}}
}

func applyGarageS3Service(store *buildkitecomv1alpha1.CacheStore, service *corev1.Service) {
	service.Labels = withCacheStoreLabels(service.Labels, store)
	service.Spec.Type = corev1.ServiceTypeClusterIP
	service.Spec.Selector = cacheStoreSelectorLabels(store)
	service.Spec.Ports = []corev1.ServicePort{{
		Name:       "s3",
		Protocol:   corev1.ProtocolTCP,
		Port:       garageS3Port,
		TargetPort: intstr.FromString("s3"),
	}}
}

func applyGarageStatefulSet(store *buildkitecomv1alpha1.CacheStore, statefulSet *appsv1.StatefulSet) {
	one := int32(1)
	uid := int64(1000)
	nonRoot := true
	noToken := false
	retain := appsv1.RetainPersistentVolumeClaimRetentionPolicyType
	statefulSet.Labels = withCacheStoreLabels(statefulSet.Labels, store)
	statefulSet.Spec.Replicas = &one
	statefulSet.Spec.ServiceName = garageRPCServiceName(store)
	statefulSet.Spec.Selector = &metav1.LabelSelector{MatchLabels: cacheStoreSelectorLabels(store)}
	statefulSet.Spec.PersistentVolumeClaimRetentionPolicy = &appsv1.StatefulSetPersistentVolumeClaimRetentionPolicy{
		WhenDeleted: retain,
		WhenScaled:  retain,
	}
	statefulSet.Spec.Template.Labels = withCacheStoreLabels(
		statefulSet.Spec.Template.Labels, store)
	statefulSet.Spec.Template.Spec.AutomountServiceAccountToken = &noToken
	statefulSet.Spec.Template.Spec.SecurityContext = &corev1.PodSecurityContext{
		RunAsUser:    &uid,
		RunAsGroup:   &uid,
		RunAsNonRoot: &nonRoot,
		FSGroup:      &uid,
		SeccompProfile: &corev1.SeccompProfile{
			Type: corev1.SeccompProfileTypeRuntimeDefault,
		},
	}
	statefulSet.Spec.Template.Spec.Volumes = []corev1.Volume{{
		Name: garageConfigVolumeName,
		VolumeSource: corev1.VolumeSource{ConfigMap: &corev1.ConfigMapVolumeSource{
			LocalObjectReference: corev1.LocalObjectReference{Name: store.Name},
		}},
	}}

	containers := statefulSet.Spec.Template.Spec.Containers
	i := slices.IndexFunc(containers, func(container corev1.Container) bool {
		return container.Name == garageContainerName
	})
	if i < 0 {
		containers = append(containers, corev1.Container{Name: garageContainerName})
		i = len(containers) - 1
	}
	garage := containers[i]
	statefulSet.Spec.Template.Spec.Containers = []corev1.Container{garage}
	garage = statefulSet.Spec.Template.Spec.Containers[0]
	garage.Image = desiredGarageImage(store)
	garage.Command = []string{"/garage"}
	garage.Args = []string{"server", "--single-node", "--default-bucket"}
	garage.Env = garageEnvironment(store)
	garage.Ports = []corev1.ContainerPort{
		{Name: "s3", ContainerPort: garageS3Port, Protocol: corev1.ProtocolTCP},
		{Name: "rpc", ContainerPort: garageRPCPort, Protocol: corev1.ProtocolTCP},
		{Name: "admin", ContainerPort: garageAdminPort, Protocol: corev1.ProtocolTCP},
	}
	garage.Resources = normalizedResources(store.Spec.Resources)
	garage.SecurityContext = restrictedContainerSecurityContext(uid)
	garage.VolumeMounts = []corev1.VolumeMount{
		{Name: garageDataVolumeName, MountPath: "/var/lib/garage"},
		{Name: garageConfigVolumeName, MountPath: "/etc/garage.toml", SubPath: "garage.toml", ReadOnly: true},
	}
	garage.ReadinessProbe = garageHealthProbe()
	garage.LivenessProbe = garageHealthProbe()
	statefulSet.Spec.Template.Spec.Containers[0] = garage

	if len(statefulSet.Spec.VolumeClaimTemplates) == 0 {
		statefulSet.Spec.VolumeClaimTemplates = []corev1.PersistentVolumeClaim{{
			ObjectMeta: metav1.ObjectMeta{Name: garageDataVolumeName},
			Spec: corev1.PersistentVolumeClaimSpec{
				AccessModes:      []corev1.PersistentVolumeAccessMode{corev1.ReadWriteOnce},
				StorageClassName: store.Spec.Storage.StorageClassName,
				Resources: corev1.VolumeResourceRequirements{Requests: corev1.ResourceList{
					corev1.ResourceStorage: store.Spec.Storage.Size,
				}},
			},
		}}
	}
}

func garageEnvironment(store *buildkitecomv1alpha1.CacheStore) []corev1.EnvVar {
	return []corev1.EnvVar{
		{
			Name: "GARAGE_RPC_SECRET",
			ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{
				LocalObjectReference: corev1.LocalObjectReference{Name: store.Spec.RPCSecretRef.Name},
				Key:                  store.Spec.RPCSecretRef.Key,
			}},
		},
		{
			Name: "GARAGE_DEFAULT_ACCESS_KEY",
			ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{
				LocalObjectReference: corev1.LocalObjectReference{Name: store.Spec.CredentialsSecretRef.Name},
				Key:                  store.Spec.CredentialsSecretRef.AccessKeyIDKey,
			}},
		},
		{
			Name: "GARAGE_DEFAULT_SECRET_KEY",
			ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{
				LocalObjectReference: corev1.LocalObjectReference{Name: store.Spec.CredentialsSecretRef.Name},
				Key:                  store.Spec.CredentialsSecretRef.SecretAccessKeyKey,
			}},
		},
		{Name: "GARAGE_DEFAULT_BUCKET", Value: desiredCacheBucket(store)},
	}
}

func restrictedContainerSecurityContext(uid int64) *corev1.SecurityContext {
	noPrivilegeEscalation := false
	readOnly := true
	nonRoot := true
	return &corev1.SecurityContext{
		AllowPrivilegeEscalation: &noPrivilegeEscalation,
		ReadOnlyRootFilesystem:   &readOnly,
		RunAsNonRoot:             &nonRoot,
		RunAsUser:                &uid,
		RunAsGroup:               &uid,
		Capabilities:             &corev1.Capabilities{Drop: []corev1.Capability{"ALL"}},
	}
}

func garageHealthProbe() *corev1.Probe {
	return &corev1.Probe{
		ProbeHandler: corev1.ProbeHandler{HTTPGet: &corev1.HTTPGetAction{
			Path: "/health",
			Port: intstr.FromString("admin"),
		}},
		PeriodSeconds:    10,
		TimeoutSeconds:   1,
		FailureThreshold: 3,
	}
}

func (r *CacheStoreReconciler) reconcileLifecycleJob(
	ctx context.Context,
	store *buildkitecomv1alpha1.CacheStore,
) (*batchv1.Job, error) {
	hash := desiredLifecycleHash(store)
	name := lifecycleJobName(store, hash)
	waiting, err := r.removeSupersededLifecycleJobs(ctx, store, name)
	if err != nil {
		return nil, err
	}
	if waiting {
		now := metav1.Now()
		return &batchv1.Job{ObjectMeta: metav1.ObjectMeta{
			Name:              name,
			Namespace:         store.Namespace,
			DeletionTimestamp: &now,
		}}, nil
	}

	job := &batchv1.Job{}
	key := types.NamespacedName{Name: name, Namespace: store.Namespace}
	err = r.Get(ctx, key, job)
	if apierrors.IsNotFound(err) {
		job = &batchv1.Job{ObjectMeta: metav1.ObjectMeta{Name: key.Name, Namespace: key.Namespace}}
		applyLifecycleJob(store, job, hash)
		if err := ctrl.SetControllerReference(store, job, r.Scheme); err != nil {
			return nil, err
		}
		if err := r.Create(ctx, job); err != nil {
			return nil, fmt.Errorf("creating lifecycle Job %s: %w", job.Name, err)
		}
		logf.FromContext(ctx).Info("Created lifecycle Job", "cacheStore", store.Name, "job", job.Name)
		return job, nil
	}
	if err != nil {
		return nil, fmt.Errorf("getting lifecycle Job %s: %w", key.Name, err)
	}

	before := job.DeepCopy()
	applyLifecycleJob(store, job, hash)
	if err := ctrl.SetControllerReference(store, job, r.Scheme); err != nil {
		return nil, err
	}
	if !equality.Semantic.DeepEqual(before.Spec, job.Spec) {
		if err := r.Delete(ctx, before, client.PropagationPolicy(metav1.DeletePropagationForeground)); err != nil && !apierrors.IsNotFound(err) {
			return nil, fmt.Errorf("deleting drifted lifecycle Job %s: %w", job.Name, err)
		}
		now := metav1.Now()
		job.DeletionTimestamp = &now
		logf.FromContext(ctx).Info("Deleted drifted lifecycle Job", "cacheStore", store.Name, "job", job.Name)
		return job, nil
	}
	if !equality.Semantic.DeepEqual(before.Labels, job.Labels) ||
		!equality.Semantic.DeepEqual(before.Annotations, job.Annotations) ||
		!equality.Semantic.DeepEqual(before.OwnerReferences, job.OwnerReferences) {
		if err := r.Update(ctx, job); err != nil {
			return nil, fmt.Errorf("updating lifecycle Job %s metadata: %w", job.Name, err)
		}
	}
	return job, nil
}

func applyLifecycleJob(store *buildkitecomv1alpha1.CacheStore, job *batchv1.Job, hash string) {
	uid := int64(1000)
	nonRoot := true
	noToken := false
	backoffLimit := int32(6)
	job.Labels = withCacheStoreLabels(job.Labels, store)
	if job.Annotations == nil {
		job.Annotations = map[string]string{}
	}
	job.Annotations[lifecycleHashAnnotation] = hash
	job.Spec.BackoffLimit = &backoffLimit
	job.Spec.Template.Labels = withCacheStoreLabels(job.Spec.Template.Labels, store)
	job.Spec.Template.Spec.RestartPolicy = corev1.RestartPolicyNever
	job.Spec.Template.Spec.AutomountServiceAccountToken = &noToken
	job.Spec.Template.Spec.SecurityContext = &corev1.PodSecurityContext{
		RunAsUser:    &uid,
		RunAsGroup:   &uid,
		RunAsNonRoot: &nonRoot,
		FSGroup:      &uid,
		SeccompProfile: &corev1.SeccompProfile{
			Type: corev1.SeccompProfileTypeRuntimeDefault,
		},
	}
	job.Spec.Template.Spec.Volumes = []corev1.Volume{{
		Name:         lifecycleTempVolumeName,
		VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}},
	}}

	containers := job.Spec.Template.Spec.Containers
	i := slices.IndexFunc(containers, func(container corev1.Container) bool {
		return container.Name == lifecycleContainerName
	})
	if i < 0 {
		containers = append(containers, corev1.Container{Name: lifecycleContainerName})
		i = len(containers) - 1
	}
	container := containers[i]
	job.Spec.Template.Spec.Containers = []corev1.Container{container}
	container = job.Spec.Template.Spec.Containers[0]
	container.Image = desiredLifecycleImage(store)
	container.Command = []string{"/bin/sh", "-ec"}
	container.Args = []string{lifecycleScript(store)}
	container.WorkingDir = lifecycleWorkingDir
	container.Env = lifecycleEnvironment(store)
	container.SecurityContext = restrictedContainerSecurityContext(uid)
	container.VolumeMounts = []corev1.VolumeMount{{Name: lifecycleTempVolumeName, MountPath: lifecycleWorkingDir}}
	job.Spec.Template.Spec.Containers[0] = container
}

func lifecycleScript(store *buildkitecomv1alpha1.CacheStore) string {
	configuration := fmt.Sprintf(
		`{"Rules":[{"ID":"buildkite-cache-retention","Status":"Enabled","Filter":{"Prefix":""},"Expiration":{"Days":%d},"AbortIncompleteMultipartUpload":{"DaysAfterInitiation":1}}]}`,
		desiredRetentionDays(store))
	query := fmt.Sprintf(
		"length(Rules[?ID==`\"buildkite-cache-retention\"` && Status==`\"Enabled\"` && Expiration.Days==`%d` && AbortIncompleteMultipartUpload.DaysAfterInitiation==`1`])",
		desiredRetentionDays(store))
	return fmt.Sprintf(`until aws --endpoint-url "$AWS_ENDPOINT_URL" s3api head-bucket --bucket "$BUCKET"; do
  sleep 2
done
aws --endpoint-url "$AWS_ENDPOINT_URL" s3api put-bucket-lifecycle-configuration \
  --bucket "$BUCKET" \
  --lifecycle-configuration '%s'
test "$(aws --endpoint-url "$AWS_ENDPOINT_URL" s3api get-bucket-lifecycle-configuration \
  --bucket "$BUCKET" --query '%s' --output text)" = "1"
`, configuration, query)
}

func lifecycleEnvironment(store *buildkitecomv1alpha1.CacheStore) []corev1.EnvVar {
	return []corev1.EnvVar{
		{Name: "AWS_ENDPOINT_URL", Value: garageS3Endpoint(store)},
		{Name: "AWS_DEFAULT_REGION", Value: garageRegion},
		{Name: "AWS_EC2_METADATA_DISABLED", Value: "true"},
		{Name: "AWS_PAGER", Value: ""},
		{Name: "HOME", Value: lifecycleWorkingDir},
		{Name: "BUCKET", Value: desiredCacheBucket(store)},
		{
			Name: "AWS_ACCESS_KEY_ID",
			ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{
				LocalObjectReference: corev1.LocalObjectReference{Name: store.Spec.CredentialsSecretRef.Name},
				Key:                  store.Spec.CredentialsSecretRef.AccessKeyIDKey,
			}},
		},
		{
			Name: "AWS_SECRET_ACCESS_KEY",
			ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{
				LocalObjectReference: corev1.LocalObjectReference{Name: store.Spec.CredentialsSecretRef.Name},
				Key:                  store.Spec.CredentialsSecretRef.SecretAccessKeyKey,
			}},
		},
	}
}

func (r *CacheStoreReconciler) removeSupersededLifecycleJobs(
	ctx context.Context,
	store *buildkitecomv1alpha1.CacheStore,
	currentName string,
) (bool, error) {
	jobs := &batchv1.JobList{}
	if err := r.List(ctx, jobs, client.InNamespace(store.Namespace), client.MatchingLabels{
		cacheStoreLabel: store.Name,
	}); err != nil {
		return false, fmt.Errorf("listing lifecycle Jobs for CacheStore %s: %w", store.Name, err)
	}
	waiting := false
	for i := range jobs.Items {
		job := &jobs.Items[i]
		if job.Name == currentName || !metav1.IsControlledBy(job, store) {
			continue
		}
		waiting = true
		if !job.DeletionTimestamp.IsZero() {
			continue
		}
		if err := r.Delete(ctx, job, client.PropagationPolicy(metav1.DeletePropagationForeground)); err != nil && !apierrors.IsNotFound(err) {
			return false, fmt.Errorf("deleting superseded lifecycle Job %s: %w", job.Name, err)
		}
		logf.FromContext(ctx).Info("Deleted superseded lifecycle Job",
			"cacheStore", store.Name, "job", job.Name)
	}
	return waiting, nil
}

func cacheStoreReadyCondition(
	store *buildkitecomv1alpha1.CacheStore,
	statefulSet *appsv1.StatefulSet,
	job *batchv1.Job,
) metav1.Condition {
	condition := metav1.Condition{
		Type:               buildkitecomv1alpha1.CacheStoreConditionReady,
		ObservedGeneration: store.Generation,
	}
	if statefulSet.Status.ObservedGeneration < statefulSet.Generation || statefulSet.Status.ReadyReplicas < 1 {
		condition.Status = metav1.ConditionUnknown
		condition.Reason = "StatefulSetPending"
		condition.Message = fmt.Sprintf("Waiting for StatefulSet %s to become ready", statefulSet.Name)
		return condition
	}
	if job.DeletionTimestamp != nil {
		condition.Status = metav1.ConditionUnknown
		condition.Reason = "LifecycleConfiguring"
		condition.Message = fmt.Sprintf("Waiting to recreate lifecycle Job %s", job.Name)
		return condition
	}
	if complete := jobCondition(job, batchv1.JobComplete); complete != nil && complete.Status == corev1.ConditionTrue {
		condition.Status = metav1.ConditionTrue
		condition.Reason = "CacheStoreAvailable"
		condition.Message = "Garage is ready and the bucket lifecycle configuration is applied"
		return condition
	}
	if failed := jobCondition(job, batchv1.JobFailed); failed != nil && failed.Status == corev1.ConditionTrue {
		condition.Status = metav1.ConditionFalse
		condition.Reason = "LifecycleConfigurationFailed"
		condition.Message = cmp.Or(failed.Message, fmt.Sprintf("Lifecycle Job %s failed", job.Name))
		return condition
	}
	condition.Status = metav1.ConditionUnknown
	condition.Reason = "LifecycleConfiguring"
	condition.Message = fmt.Sprintf("Waiting for lifecycle Job %s to succeed", job.Name)
	return condition
}

func jobCondition(job *batchv1.Job, conditionType batchv1.JobConditionType) *batchv1.JobCondition {
	i := slices.IndexFunc(job.Status.Conditions, func(condition batchv1.JobCondition) bool {
		return condition.Type == conditionType
	})
	if i < 0 {
		return nil
	}
	return &job.Status.Conditions[i]
}

func desiredLifecycleHash(store *buildkitecomv1alpha1.CacheStore) string {
	hash := sha256.New()
	_, _ = fmt.Fprintf(hash, "%s\x00%s\x00%d\x00%s\x00%s\x00%s\x00%s",
		desiredLifecycleImage(store), desiredCacheBucket(store), desiredRetentionDays(store),
		store.Spec.CredentialsSecretRef.Name, store.Spec.CredentialsSecretRef.AccessKeyIDKey,
		store.Spec.CredentialsSecretRef.SecretAccessKeyKey, garageS3Endpoint(store))
	return hex.EncodeToString(hash.Sum(nil))[:10]
}

func desiredGarageImage(store *buildkitecomv1alpha1.CacheStore) string {
	if store.Spec.Image != "" {
		return store.Spec.Image
	}
	return defaultGarageImage
}

func desiredLifecycleImage(store *buildkitecomv1alpha1.CacheStore) string {
	if store.Spec.LifecycleImage != "" {
		return store.Spec.LifecycleImage
	}
	return defaultLifecycleImage
}

func desiredCacheBucket(store *buildkitecomv1alpha1.CacheStore) string {
	if store.Spec.Bucket != "" {
		return store.Spec.Bucket
	}
	return defaultCacheBucket
}

func desiredRetentionDays(store *buildkitecomv1alpha1.CacheStore) int32 {
	if store.Spec.RetentionDays > 0 {
		return store.Spec.RetentionDays
	}
	return defaultRetentionDays
}

func garageS3Endpoint(store *buildkitecomv1alpha1.CacheStore) string {
	return fmt.Sprintf("http://%s.%s.svc:%d", store.Name, store.Namespace, garageS3Port)
}

func garageRPCServiceName(store *buildkitecomv1alpha1.CacheStore) string {
	return suffixedResourceName(store.Name, "rpc")
}

func lifecycleJobName(store *buildkitecomv1alpha1.CacheStore, hash string) string {
	return suffixedResourceName(store.Name, "lifecycle-"+hash)
}

func suffixedResourceName(base, suffix string) string {
	name := base + "-" + suffix
	if len(name) <= 63 {
		return name
	}
	digest := sha256.Sum256([]byte(name))
	tail := hex.EncodeToString(digest[:])[:8]
	maxBase := 63 - len(suffix) - len(tail) - 2
	base = strings.TrimRight(base[:maxBase], "-")
	return base + "-" + suffix + "-" + tail
}

func cacheStoreSelectorLabels(store *buildkitecomv1alpha1.CacheStore) map[string]string {
	return map[string]string{
		"app.kubernetes.io/name":     garageContainerName,
		"app.kubernetes.io/instance": store.Name,
	}
}

func withCacheStoreLabels(have map[string]string, store *buildkitecomv1alpha1.CacheStore) map[string]string {
	if have == nil {
		have = map[string]string{}
	}
	maps.Copy(have, cacheStoreSelectorLabels(store))
	have["app.kubernetes.io/managed-by"] = "buildkite-operator"
	have[cacheStoreLabel] = store.Name
	return have
}

func (r *CacheStoreReconciler) cacheStoresForSecret(
	ctx context.Context,
	object client.Object,
) []reconcile.Request {
	requests := map[types.NamespacedName]struct{}{}
	for _, field := range []string{cacheStoreRPCSecretIndex, cacheStoreCredsIndex} {
		stores := &buildkitecomv1alpha1.CacheStoreList{}
		if err := r.List(ctx, stores, client.InNamespace(object.GetNamespace()), client.MatchingFields{
			field: object.GetName(),
		}); err != nil {
			logf.FromContext(ctx).Error(err, "Could not list CacheStores for Secret", "secret", object.GetName())
			continue
		}
		for i := range stores.Items {
			requests[client.ObjectKeyFromObject(&stores.Items[i])] = struct{}{}
		}
	}
	result := make([]reconcile.Request, 0, len(requests))
	for key := range requests {
		result = append(result, reconcile.Request{NamespacedName: key})
	}
	slices.SortFunc(result, func(a, b reconcile.Request) int {
		return strings.Compare(a.String(), b.String())
	})
	return result
}

// SetupWithManager sets up the controller with watches for owned resources and
// referenced Secrets.
func (r *CacheStoreReconciler) SetupWithManager(mgr ctrl.Manager) error {
	if err := mgr.GetFieldIndexer().IndexField(context.Background(), &buildkitecomv1alpha1.CacheStore{},
		cacheStoreRPCSecretIndex, func(object client.Object) []string {
			return []string{object.(*buildkitecomv1alpha1.CacheStore).Spec.RPCSecretRef.Name}
		}); err != nil {
		return fmt.Errorf("indexing CacheStores by RPC Secret: %w", err)
	}
	if err := mgr.GetFieldIndexer().IndexField(context.Background(), &buildkitecomv1alpha1.CacheStore{},
		cacheStoreCredsIndex, func(object client.Object) []string {
			return []string{object.(*buildkitecomv1alpha1.CacheStore).Spec.CredentialsSecretRef.Name}
		}); err != nil {
		return fmt.Errorf("indexing CacheStores by credentials Secret: %w", err)
	}

	return ctrl.NewControllerManagedBy(mgr).
		For(&buildkitecomv1alpha1.CacheStore{}).
		Owns(&corev1.ConfigMap{}).
		Owns(&corev1.Service{}).
		Owns(&appsv1.StatefulSet{}).
		Owns(&batchv1.Job{}).
		Watches(&corev1.Secret{}, handler.EnqueueRequestsFromMapFunc(r.cacheStoresForSecret)).
		Named("cachestore").
		Complete(r)
}
