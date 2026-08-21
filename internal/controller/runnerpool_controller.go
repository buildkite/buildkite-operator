// Copyright (c) 2026 Buildkite Pty Ltd
// SPDX-License-Identifier: MIT

package controller

import (
	"cmp"
	"context"
	"fmt"
	"maps"
	"slices"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/equality"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	logf "sigs.k8s.io/controller-runtime/pkg/log"

	buildkitecomv1alpha1 "github.com/buildkite/buildkite-operator/api/v1alpha1"
)

const (
	// agentContainerName is the name of the Buildkite agent container within
	// each pod of a pool's Deployment.
	agentContainerName = "agent"

	// defaultAgentImage matches the CRD default for spec.image, and is applied
	// again here so a RunnerPool built in Go (rather than admitted by the API
	// server) still reconciles into something runnable.
	defaultAgentImage = "buildkite/agent:3"

	// defaultReplicas matches the CRD default for spec.replicas.
	defaultReplicas int32 = 1

	// poolLabel names the RunnerPool that owns a resource.
	poolLabel = "buildkite.com/runner-pool"
)

// RunnerPoolReconciler reconciles a RunnerPool object
type RunnerPoolReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// +kubebuilder:rbac:groups=buildkite.com,resources=runnerpools,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=buildkite.com,resources=runnerpools/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=buildkite.com,resources=runnerpools/finalizers,verbs=update
// +kubebuilder:rbac:groups=apps,resources=deployments,verbs=get;list;watch;create;update;patch;delete

// Reconcile drives a RunnerPool towards its desired state: a Deployment of
// Buildkite agents registered with the pool's queue.
func (r *RunnerPoolReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := logf.FromContext(ctx)

	pool := &buildkitecomv1alpha1.RunnerPool{}
	if err := r.Get(ctx, req.NamespacedName, pool); err != nil {
		// A deleted pool takes its Deployment with it via the owner reference,
		// so there is nothing left to do.
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	deployment := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{
			Name:      deploymentName(pool),
			Namespace: pool.Namespace,
		},
	}

	op, err := controllerutil.CreateOrUpdate(ctx, r.Client, deployment, func() error {
		return r.applyAgentDeployment(pool, deployment)
	})
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("reconciling deployment %s: %w", deployment.Name, err)
	}
	if op != controllerutil.OperationResultNone {
		log.Info("reconciled agent deployment", "deployment", deployment.Name, "operation", op)
	}

	if err := r.reconcileStatus(ctx, pool, deployment); err != nil {
		// A conflict means someone else wrote the pool first; the next reconcile
		// recomputes status from fresh state.
		if apierrors.IsConflict(err) {
			return ctrl.Result{Requeue: true}, nil
		}
		return ctrl.Result{}, fmt.Errorf("updating status of runnerpool %s: %w", pool.Name, err)
	}

	return ctrl.Result{}, nil
}

// reconcileStatus reports what the pool's Deployment is actually doing. It
// writes only when something changed, so that a status update does not wake the
// controller into writing an identical status again.
func (r *RunnerPoolReconciler) reconcileStatus(
	ctx context.Context,
	pool *buildkitecomv1alpha1.RunnerPool,
	deployment *appsv1.Deployment,
) error {
	updated := pool.DeepCopy()
	updated.Status.ReadyReplicas = deployment.Status.ReadyReplicas
	updated.Status.ObservedGeneration = pool.Generation
	meta.SetStatusCondition(&updated.Status.Conditions, readyCondition(pool, deployment))

	if equality.Semantic.DeepEqual(pool.Status, updated.Status) {
		return nil
	}
	return r.Status().Update(ctx, updated)
}

// readyCondition translates the Deployment's Available condition into the
// pool's Ready condition.
func readyCondition(
	pool *buildkitecomv1alpha1.RunnerPool,
	deployment *appsv1.Deployment,
) metav1.Condition {
	condition := metav1.Condition{
		Type:               buildkitecomv1alpha1.RunnerPoolConditionReady,
		ObservedGeneration: pool.Generation,
	}

	available := deploymentCondition(deployment, appsv1.DeploymentAvailable)
	switch {
	case available == nil:
		condition.Status = metav1.ConditionUnknown
		condition.Reason = "DeploymentPending"
		condition.Message = fmt.Sprintf("Waiting for deployment %s to report availability", deployment.Name)

	case available.Status == corev1.ConditionTrue:
		condition.Status = metav1.ConditionTrue
		condition.Reason = "AgentsAvailable"
		condition.Message = fmt.Sprintf("%d of %d agents ready",
			deployment.Status.ReadyReplicas, desiredReplicas(pool))

	default:
		condition.Status = metav1.ConditionFalse
		condition.Reason = cmp.Or(available.Reason, "DeploymentUnavailable")
		condition.Message = cmp.Or(available.Message,
			fmt.Sprintf("Deployment %s is not available", deployment.Name))
	}

	return condition
}

// deploymentCondition returns the named condition, or nil if the Deployment has
// not reported it yet.
func deploymentCondition(
	deployment *appsv1.Deployment,
	conditionType appsv1.DeploymentConditionType,
) *appsv1.DeploymentCondition {
	i := slices.IndexFunc(deployment.Status.Conditions, func(c appsv1.DeploymentCondition) bool {
		return c.Type == conditionType
	})
	if i < 0 {
		return nil
	}
	return &deployment.Status.Conditions[i]
}

// applyAgentDeployment mutates deployment into the shape pool asks for.
//
// It only ever touches the fields this controller owns, mutating the agent
// container in place rather than replacing the pod spec. Replacing it wholesale
// would discard the defaults the API server fills in (imagePullPolicy,
// terminationMessagePath and friends), so every reconcile would see a diff and
// issue an update, and every update would trigger another reconcile.
func (r *RunnerPoolReconciler) applyAgentDeployment(
	pool *buildkitecomv1alpha1.RunnerPool,
	deployment *appsv1.Deployment,
) error {
	replicas := desiredReplicas(pool)
	deployment.Labels = withLabels(deployment.Labels, poolLabels(pool))
	deployment.Spec.Replicas = &replicas
	deployment.Spec.Selector = &metav1.LabelSelector{MatchLabels: selectorLabels(pool)}
	deployment.Spec.Template.Labels = withLabels(deployment.Spec.Template.Labels, poolLabels(pool))

	containers := deployment.Spec.Template.Spec.Containers
	i := slices.IndexFunc(containers, func(c corev1.Container) bool { return c.Name == agentContainerName })
	if i < 0 {
		containers = append(containers, corev1.Container{Name: agentContainerName})
		i = len(containers) - 1
		deployment.Spec.Template.Spec.Containers = containers
	}
	agent := &deployment.Spec.Template.Spec.Containers[i]

	// No command or args: the agent image's entrypoint already starts the agent.
	agent.Image = desiredImage(pool)
	agent.Env = agentEnv(pool)

	// The API server defaults an unset request to its matching limit, so
	// normalize the desired resources the same way and compare with DeepEqual.
	// DeepDerivative would treat every omitted request, limit or map entry as
	// already satisfied, so removing requests.cpu (or clearing resources
	// entirely) would never reconcile and the stale value would linger on the
	// Deployment forever.
	if want := desiredResources(pool); !equality.Semantic.DeepEqual(want, agent.Resources) {
		agent.Resources = want
	}

	return ctrl.SetControllerReference(pool, deployment, r.Scheme)
}

// agentEnv is the environment every agent in the pool runs with.
func agentEnv(pool *buildkitecomv1alpha1.RunnerPool) []corev1.EnvVar {
	tokenRef := pool.Spec.AgentTokenSecretRef
	return []corev1.EnvVar{
		{
			Name:      "BUILDKITE_AGENT_TOKEN",
			ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &tokenRef},
		},
		{
			Name:  "BUILDKITE_AGENT_TAGS",
			Value: "queue=" + pool.Spec.Queue,
		},
	}
}

// deploymentName is the name of the Deployment owned by pool.
func deploymentName(pool *buildkitecomv1alpha1.RunnerPool) string {
	return pool.Name + "-agent"
}

// selectorLabels identify the pods belonging to pool. They are part of the
// Deployment's immutable selector, so they must be derived only from values
// that cannot change over a pool's lifetime.
func selectorLabels(pool *buildkitecomv1alpha1.RunnerPool) map[string]string {
	return map[string]string{
		"app.kubernetes.io/name":     "buildkite-agent",
		"app.kubernetes.io/instance": pool.Name,
	}
}

// poolLabels are the selector labels plus labels that are safe to change.
func poolLabels(pool *buildkitecomv1alpha1.RunnerPool) map[string]string {
	labels := selectorLabels(pool)
	labels["app.kubernetes.io/managed-by"] = "buildkite-operator"
	labels[poolLabel] = pool.Name
	return labels
}

// withLabels merges want into have, leaving any other labels alone.
func withLabels(have, want map[string]string) map[string]string {
	if have == nil {
		have = make(map[string]string, len(want))
	}
	maps.Copy(have, want)
	return have
}

func desiredReplicas(pool *buildkitecomv1alpha1.RunnerPool) int32 {
	if pool.Spec.Replicas != nil {
		return *pool.Spec.Replicas
	}
	return defaultReplicas
}

func desiredImage(pool *buildkitecomv1alpha1.RunnerPool) string {
	if pool.Spec.Image != "" {
		return pool.Spec.Image
	}
	return defaultAgentImage
}

// desiredResources returns the resource requirements the controller wants on
// the agent container, normalized the way the API server normalizes them.
//
// Kubernetes defaults an unset request to its matching limit. Replaying that
// defaulting here means a Deployment whose requests were filled in from limits
// does not read as drift, while a genuine change (including removing a request
// or a limit) still does, so it can be reconciled with a full DeepEqual.
func desiredResources(pool *buildkitecomv1alpha1.RunnerPool) corev1.ResourceRequirements {
	want := *pool.Spec.Resources.DeepCopy()
	if len(want.Limits) == 0 {
		return want
	}
	if want.Requests == nil {
		want.Requests = make(corev1.ResourceList, len(want.Limits))
	}
	for name, quantity := range want.Limits {
		if _, ok := want.Requests[name]; !ok {
			want.Requests[name] = quantity.DeepCopy()
		}
	}
	return want
}

// SetupWithManager sets up the controller with the Manager.
func (r *RunnerPoolReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&buildkitecomv1alpha1.RunnerPool{}).
		Owns(&appsv1.Deployment{}).
		Named("runnerpool").
		Complete(r)
}
