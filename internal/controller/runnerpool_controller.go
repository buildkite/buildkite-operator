// Copyright (c) 2026 Buildkite Pty Ltd
// SPDX-License-Identifier: MIT

package controller

import (
	"cmp"
	"context"
	"fmt"
	"slices"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/equality"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	logf "sigs.k8s.io/controller-runtime/pkg/log"

	buildkitecomv1alpha1 "github.com/buildkite/buildkite-operator/api/v1alpha1"
)

const (
	agentContainerName = "agent"
	defaultAgentImage  = "buildkite/agent:3"

	agentHealthPort     int32 = 8080
	agentHealthPortName       = "health"

	defaultTerminationGracePeriodSeconds int64 = 3600
	defaultMinIdleRunners                int32 = 1
	defaultIdleTimeoutSeconds            int32 = 10
	defaultPollInterval                        = 10 * time.Second

	poolLabel                 = "buildkite.com/runner-pool"
	idleSinceAnnotation       = "buildkite.com/idle-since"
	podTemplateHashAnnotation = "buildkite.com/pod-template-hash"
)

// RunnerPoolReconciler reconciles a RunnerPool object.
type RunnerPoolReconciler struct {
	client.Client
	Scheme        *runtime.Scheme
	StatusChecker AgentStatusChecker
	PollInterval  time.Duration
}

// +kubebuilder:rbac:groups=buildkite.com,resources=runnerpools,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=buildkite.com,resources=runnerpools/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=buildkite.com,resources=runnerpools/finalizers,verbs=update
// +kubebuilder:rbac:groups="",resources=pods,verbs=get;list;watch;create;update;patch;delete

// Reconcile drives a RunnerPool towards its idle buffer using directly owned
// agent Pods so scale-down can select a confirmed-idle agent.
func (r *RunnerPoolReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	pool := &buildkitecomv1alpha1.RunnerPool{}
	if err := r.Get(ctx, req.NamespacedName, pool); err != nil {
		return ctrl.Result{}, client.IgnoreNotFound(err)
	}

	templateHash, err := desiredPodTemplateHash(pool)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("hashing Pod template for RunnerPool %s: %w", pool.Name, err)
	}

	pods, err := r.observeAgentPods(ctx, pool, templateHash)
	if err != nil {
		return ctrl.Result{}, err
	}

	if err := r.reconcileRunners(ctx, pool, pods, templateHash); err != nil {
		return ctrl.Result{}, err
	}

	if err := r.reconcileStatus(ctx, pool, pods); err != nil {
		if apierrors.IsConflict(err) {
			return ctrl.Result{Requeue: true}, nil
		}
		return ctrl.Result{}, fmt.Errorf("updating status of RunnerPool %s: %w", pool.Name, err)
	}

	return ctrl.Result{RequeueAfter: r.pollInterval(pool)}, nil
}

func (r *RunnerPoolReconciler) observeAgentPods(
	ctx context.Context,
	pool *buildkitecomv1alpha1.RunnerPool,
	templateHash string,
) ([]observedPod, error) {
	log := logf.FromContext(ctx)
	podList := &corev1.PodList{}
	if err := r.List(ctx, podList,
		client.InNamespace(pool.Namespace),
		client.MatchingLabels{poolLabel: pool.Name},
	); err != nil {
		return nil, fmt.Errorf("listing Pods for RunnerPool %s: %w", pool.Name, err)
	}

	now := time.Now()
	idleTimeout := time.Duration(desiredIdleTimeoutSeconds(pool)) * time.Second
	observed := make([]observedPod, 0, len(podList.Items))
	for i := range podList.Items {
		pod := &podList.Items[i]
		if !metav1.IsControlledBy(pod, pool) {
			continue
		}
		if !pod.DeletionTimestamp.IsZero() {
			// Still holds a capacity slot until Kubernetes finishes deleting it,
			// so it must stay in the pool's total to keep maxRunners a hard cap.
			// Excluded from polling and eviction since it is already draining.
			observed = append(observed, observedPod{pod: pod, terminating: true})
			continue
		}
		if pod.Status.Phase == corev1.PodSucceeded || pod.Status.Phase == corev1.PodFailed {
			if err := r.Delete(ctx, pod); client.IgnoreNotFound(err) != nil {
				return nil, fmt.Errorf("deleting terminal agent Pod %s: %w", pod.Name, err)
			}
			log.Info("Deleted terminal agent Pod", "pod", pod.Name, "phase", pod.Status.Phase)
			continue
		}

		state := observedPod{
			pod:   pod,
			ready: podReady(pod),
			stale: pod.Annotations[podTemplateHashAnnotation] != templateHash,
		}
		if pod.Status.PodIP == "" || !state.ready {
			if err := r.clearIdleSince(ctx, pod); err != nil {
				return nil, err
			}
			observed = append(observed, state)
			continue
		}

		status, err := r.checkAgentStatus(ctx, pod)
		if err != nil {
			log.Info("Could not check agent Pod status", "pod", pod.Name, "error", err)
			if err := r.clearIdleSince(ctx, pod); err != nil {
				return nil, err
			}
			observed = append(observed, state)
			continue
		}

		switch status {
		case AgentStatusBusy:
			state.busy = true
			if err := r.clearIdleSince(ctx, pod); err != nil {
				return nil, err
			}

		case AgentStatusIdle:
			state.idle = true
			state.idleSince, err = r.ensureIdleSince(ctx, pod, now)
			if err != nil {
				return nil, err
			}
			state.eligible = state.stale || !now.Before(state.idleSince.Add(idleTimeout))
		}

		observed = append(observed, state)
	}
	return observed, nil
}

func (r *RunnerPoolReconciler) checkAgentStatus(ctx context.Context, pod *corev1.Pod) (AgentStatus, error) {
	if r.StatusChecker == nil {
		return "", fmt.Errorf("agent status checker is not configured")
	}
	return r.StatusChecker.Check(ctx, pod.Status.PodIP, agentHealthPort)
}

func (r *RunnerPoolReconciler) ensureIdleSince(
	ctx context.Context,
	pod *corev1.Pod,
	now time.Time,
) (time.Time, error) {
	if value := pod.Annotations[idleSinceAnnotation]; value != "" {
		if idleSince, err := time.Parse(time.RFC3339, value); err == nil {
			return idleSince, nil
		}
	}

	original := pod.DeepCopy()
	if pod.Annotations == nil {
		pod.Annotations = make(map[string]string, 1)
	}
	idleSince := now.UTC()
	pod.Annotations[idleSinceAnnotation] = idleSince.Format(time.RFC3339Nano)
	if err := r.Patch(ctx, pod, client.MergeFrom(original)); err != nil {
		return time.Time{}, fmt.Errorf("setting idle timestamp on agent Pod %s: %w", pod.Name, err)
	}
	return idleSince, nil
}

func (r *RunnerPoolReconciler) clearIdleSince(ctx context.Context, pod *corev1.Pod) error {
	if pod.Annotations == nil || pod.Annotations[idleSinceAnnotation] == "" {
		return nil
	}
	original := pod.DeepCopy()
	delete(pod.Annotations, idleSinceAnnotation)
	if len(pod.Annotations) == 0 {
		pod.Annotations = nil
	}
	if err := r.Patch(ctx, pod, client.MergeFrom(original)); err != nil {
		return fmt.Errorf("clearing idle timestamp on agent Pod %s: %w", pod.Name, err)
	}
	return nil
}

func (r *RunnerPoolReconciler) reconcileRunners(
	ctx context.Context,
	pool *buildkitecomv1alpha1.RunnerPool,
	pods []observedPod,
	templateHash string,
) error {
	total := int32(len(pods))
	desired := desiredTotal(pool, pods)

	if total < desired {
		return r.createAgentPods(ctx, pool, templateHash, desired-total)
	}

	if total > desired {
		confirmedIdle := countIdle(pods)
		deleteCount := min(total-desired, confirmedIdle-desiredMinIdleRunners(pool))
		if deleteCount > 0 {
			return r.deleteAgentPods(ctx, pods, templateHash, deleteCount, false)
		}
		return nil
	}

	stale := countStale(pods)
	if stale == 0 {
		return nil
	}
	currentTotal, currentBusy := countCurrent(pods)
	desiredCurrentTotal := min(currentBusy+desiredMinIdleRunners(pool), pool.Spec.MaxRunners)
	if currentTotal >= desiredCurrentTotal {
		return nil
	}

	// Roll immutable template changes without deleting a busy agent. Surge by
	// one when the hard cap permits it; at the cap, remove one idle stale Pod
	// first and replace it on the next reconcile.
	if total < pool.Spec.MaxRunners {
		return r.createAgentPods(ctx, pool, templateHash, 1)
	}
	return r.deleteAgentPods(ctx, pods, templateHash, 1, true)
}

func (r *RunnerPoolReconciler) createAgentPods(
	ctx context.Context,
	pool *buildkitecomv1alpha1.RunnerPool,
	templateHash string,
	count int32,
) error {
	log := logf.FromContext(ctx)
	for range count {
		pod, err := r.agentPod(pool, templateHash)
		if err != nil {
			return fmt.Errorf("building agent Pod for RunnerPool %s: %w", pool.Name, err)
		}
		if err := r.Create(ctx, pod); err != nil {
			return fmt.Errorf("creating agent Pod for RunnerPool %s: %w", pool.Name, err)
		}
		log.Info("Created agent Pod", "pod", pod.Name)
	}
	return nil
}

func (r *RunnerPoolReconciler) deleteAgentPods(
	ctx context.Context,
	pods []observedPod,
	templateHash string,
	count int32,
	staleOnly bool,
) error {
	candidates := append([]observedPod(nil), pods...)
	slices.SortFunc(candidates, func(a, b observedPod) int {
		if a.stale != b.stale {
			if a.stale {
				return -1
			}
			return 1
		}
		if !a.idleSince.Equal(b.idleSince) {
			if a.idleSince.Before(b.idleSince) {
				return -1
			}
			return 1
		}
		return cmp.Compare(a.pod.Name, b.pod.Name)
	})

	deleted := int32(0)
	for i := range candidates {
		candidate := &candidates[i]
		if !candidate.idle || (staleOnly && !candidate.stale) || (!staleOnly && !candidate.eligible) {
			continue
		}
		wasDeleted, err := r.reconfirmAndDelete(ctx, candidate.pod, templateHash, staleOnly)
		if err != nil {
			return err
		}
		if wasDeleted {
			deleted++
		}
		if deleted == count {
			break
		}
	}
	return nil
}

func (r *RunnerPoolReconciler) reconfirmAndDelete(
	ctx context.Context,
	pod *corev1.Pod,
	templateHash string,
	staleOnly bool,
) (bool, error) {
	current := &corev1.Pod{}
	if err := r.Get(ctx, client.ObjectKeyFromObject(pod), current); err != nil {
		if apierrors.IsNotFound(err) {
			return false, nil
		}
		return false, fmt.Errorf("refreshing agent Pod %s before deletion: %w", pod.Name, err)
	}
	if !current.DeletionTimestamp.IsZero() || !podReady(current) || current.Status.PodIP == "" {
		return false, nil
	}
	if staleOnly && current.Annotations[podTemplateHashAnnotation] == templateHash {
		return false, nil
	}

	status, err := r.checkAgentStatus(ctx, current)
	if err != nil || status != AgentStatusIdle {
		if err := r.clearIdleSince(ctx, current); err != nil {
			return false, err
		}
		return false, nil
	}
	if err := r.Delete(ctx, current); err != nil {
		return false, fmt.Errorf("deleting idle agent Pod %s: %w", current.Name, err)
	}
	logf.FromContext(ctx).Info("Deleted idle agent Pod", "pod", current.Name)
	return true, nil
}

func (r *RunnerPoolReconciler) reconcileStatus(
	ctx context.Context,
	pool *buildkitecomv1alpha1.RunnerPool,
	pods []observedPod,
) error {
	updated := pool.DeepCopy()
	updated.Status.TotalRunners = countNonTerminating(pods)
	updated.Status.IdleRunners = countIdle(pods)
	updated.Status.BusyRunners = countBusy(pods)
	updated.Status.ReadyRunners = countReady(pods)
	updated.Status.ObservedGeneration = pool.Generation
	meta.SetStatusCondition(&updated.Status.Conditions, readyCondition(pool, pods))

	if equality.Semantic.DeepEqual(pool.Status, updated.Status) {
		return nil
	}
	return r.Status().Update(ctx, updated)
}

func readyCondition(pool *buildkitecomv1alpha1.RunnerPool, pods []observedPod) metav1.Condition {
	total := countNonTerminating(pods)
	desired := desiredTotal(pool, pods)
	ready := countReady(pods)
	stale := countStale(pods)
	condition := metav1.Condition{
		Type:               buildkitecomv1alpha1.RunnerPoolConditionReady,
		ObservedGeneration: pool.Generation,
	}

	switch {
	case stale > 0:
		condition.Status = metav1.ConditionFalse
		condition.Reason = "RollingUpdate"
		condition.Message = fmt.Sprintf("Replacing %d stale agent Pods", stale)
	case total != desired:
		condition.Status = metav1.ConditionFalse
		condition.Reason = "Scaling"
		condition.Message = fmt.Sprintf("Scaling from %d to %d agent Pods", total, desired)
	case ready != total:
		condition.Status = metav1.ConditionFalse
		condition.Reason = "PodsNotReady"
		condition.Message = fmt.Sprintf("%d of %d agents ready", ready, total)
	default:
		condition.Status = metav1.ConditionTrue
		condition.Reason = "AgentsReady"
		condition.Message = fmt.Sprintf("%d of %d agents ready", ready, total)
	}
	return condition
}

func desiredTotal(pool *buildkitecomv1alpha1.RunnerPool, pods []observedPod) int32 {
	return min(countBusy(pods)+desiredMinIdleRunners(pool), pool.Spec.MaxRunners)
}

func (r *RunnerPoolReconciler) pollInterval(pool *buildkitecomv1alpha1.RunnerPool) time.Duration {
	interval := r.PollInterval
	if interval <= 0 {
		interval = defaultPollInterval
	}
	idleTimeout := time.Duration(desiredIdleTimeoutSeconds(pool)) * time.Second
	if idleTimeout > 0 && idleTimeout < interval {
		return idleTimeout
	}
	return interval
}

// SetupWithManager sets up the controller with the Manager.
func (r *RunnerPoolReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&buildkitecomv1alpha1.RunnerPool{}).
		Owns(&corev1.Pod{}).
		Named("runnerpool").
		Complete(r)
}
