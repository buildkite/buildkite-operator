// Copyright (c) 2026 Buildkite Pty Ltd
// SPDX-License-Identifier: MIT

package controller

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/rand"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	buildkitecomv1alpha1 "github.com/buildkite/buildkite-operator/api/v1alpha1"
)

type fakeAgentStatusChecker struct {
	statuses  map[string]AgentStatus
	responses map[string][]AgentStatus
	errors    map[string]error
}

func (f *fakeAgentStatusChecker) Check(_ context.Context, podIP string, _ int32) (AgentStatus, error) {
	if err := f.errors[podIP]; err != nil {
		return "", err
	}
	if responses := f.responses[podIP]; len(responses) > 0 {
		f.responses[podIP] = responses[1:]
		return responses[0], nil
	}
	status, ok := f.statuses[podIP]
	if !ok {
		return "", fmt.Errorf("no status for %s", podIP)
	}
	return status, nil
}

var _ = Describe("RunnerPool Controller", func() {
	const (
		poolName             = "test-pool"
		queueName            = "macos-arm64"
		agentTokenSecretName = "buildkite-agent-token"
		agentTokenSecretKey  = "token"
		updatedAgentImage    = "buildkite/agent:3.100.0"
	)

	var (
		ctx         context.Context
		namespace   string
		reconciler  *RunnerPoolReconciler
		checker     *fakeAgentStatusChecker
		poolKey     types.NamespacedName
		nextIPOctet int
	)

	currentPool := func() *buildkitecomv1alpha1.RunnerPool {
		GinkgoHelper()
		pool := &buildkitecomv1alpha1.RunnerPool{}
		Expect(k8sClient.Get(ctx, poolKey, pool)).To(Succeed())
		return pool
	}

	reconcileNow := func() reconcile.Result {
		GinkgoHelper()
		result, err := reconciler.Reconcile(ctx, reconcile.Request{NamespacedName: poolKey})
		Expect(err).NotTo(HaveOccurred())
		return result
	}

	agentPods := func() []corev1.Pod {
		GinkgoHelper()
		list := &corev1.PodList{}
		Expect(k8sClient.List(ctx, list,
			client.InNamespace(namespace),
			client.MatchingLabels{poolLabel: poolName},
		)).To(Succeed())
		pods := make([]corev1.Pod, 0, len(list.Items))
		for i := range list.Items {
			if metav1.IsControlledBy(&list.Items[i], currentPool()) && list.Items[i].DeletionTimestamp.IsZero() {
				pods = append(pods, list.Items[i])
			}
		}
		slices.SortFunc(pods, func(a, b corev1.Pod) int { return cmp.Compare(a.Name, b.Name) })
		return pods
	}

	setPoolScaling := func(maxRunners, minIdleRunners, idleTimeout int32) {
		GinkgoHelper()
		pool := currentPool()
		pool.Spec.MaxRunners = maxRunners
		pool.Spec.MinIdleRunners = ptrTo(minIdleRunners)
		pool.Spec.IdleTimeoutSeconds = ptrTo(idleTimeout)
		Expect(k8sClient.Update(ctx, pool)).To(Succeed())
	}

	setPodStatus := func(pod corev1.Pod, status AgentStatus, ready bool) corev1.Pod {
		GinkgoHelper()
		current := &corev1.Pod{}
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(&pod), current)).To(Succeed())
		if current.Status.PodIP == "" {
			nextIPOctet++
			current.Status.PodIP = fmt.Sprintf("10.0.0.%d", nextIPOctet)
		}
		current.Status.Phase = corev1.PodRunning
		conditionStatus := corev1.ConditionFalse
		if ready {
			conditionStatus = corev1.ConditionTrue
		}
		current.Status.Conditions = []corev1.PodCondition{{
			Type:   corev1.PodReady,
			Status: conditionStatus,
		}}
		Expect(k8sClient.Status().Update(ctx, current)).To(Succeed())
		checker.statuses[current.Status.PodIP] = status
		return *current
	}

	setIdleSince := func(pod corev1.Pod, idleSince time.Time) corev1.Pod {
		GinkgoHelper()
		current := &corev1.Pod{}
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(&pod), current)).To(Succeed())
		if current.Annotations == nil {
			current.Annotations = map[string]string{}
		}
		current.Annotations[idleSinceAnnotation] = idleSince.UTC().Format(time.RFC3339)
		Expect(k8sClient.Update(ctx, current)).To(Succeed())
		return *current
	}

	createAgentPod := func() corev1.Pod {
		GinkgoHelper()
		pool := currentPool()
		templateHash, err := desiredPodTemplateHash(pool)
		Expect(err).NotTo(HaveOccurred())
		pod, err := reconciler.agentPod(pool, templateHash)
		Expect(err).NotTo(HaveOccurred())
		Expect(k8sClient.Create(ctx, pod)).To(Succeed())
		return *pod
	}

	BeforeEach(func() {
		ctx = context.Background()
		checker = &fakeAgentStatusChecker{
			statuses:  map[string]AgentStatus{},
			responses: map[string][]AgentStatus{},
			errors:    map[string]error{},
		}
		reconciler = &RunnerPoolReconciler{
			Client:        k8sClient,
			Scheme:        k8sClient.Scheme(),
			StatusChecker: checker,
			PollInterval:  time.Minute,
		}

		nextIPOctet = 0
		namespace = fmt.Sprintf("runnerpool-%s", rand.String(8))
		Expect(k8sClient.Create(ctx, &corev1.Namespace{
			ObjectMeta: metav1.ObjectMeta{Name: namespace},
		})).To(Succeed())

		poolKey = types.NamespacedName{Name: poolName, Namespace: namespace}
		Expect(k8sClient.Create(ctx, &buildkitecomv1alpha1.RunnerPool{
			ObjectMeta: metav1.ObjectMeta{Name: poolName, Namespace: namespace},
			Spec: buildkitecomv1alpha1.RunnerPoolSpec{
				Queue:      queueName,
				MaxRunners: 3,
				Image:      "buildkite/agent:3.90.0",
				AgentTokenSecretRef: corev1.SecretKeySelector{
					LocalObjectReference: corev1.LocalObjectReference{Name: agentTokenSecretName},
					Key:                  agentTokenSecretKey,
				},
			},
		})).To(Succeed())
	})

	It("creates directly owned agent Pods with health checks and graceful termination", func() {
		result := reconcileNow()
		Expect(result.RequeueAfter).To(Equal(10 * time.Second))

		pods := agentPods()
		Expect(pods).To(HaveLen(1))
		pod := pods[0]
		Expect(pod.GenerateName).To(Equal(poolName + "-agent-"))
		Expect(pod.Labels).To(HaveKeyWithValue(poolLabel, poolName))
		Expect(pod.Annotations[podTemplateHashAnnotation]).NotTo(BeEmpty())
		Expect(pod.OwnerReferences).To(HaveLen(1))
		Expect(pod.OwnerReferences[0].Kind).To(Equal("RunnerPool"))
		Expect(pod.Spec.TerminationGracePeriodSeconds).To(HaveValue(BeEquivalentTo(3600)))

		Expect(pod.Spec.Containers).To(HaveLen(1))
		agent := pod.Spec.Containers[0]
		Expect(agent.Name).To(Equal(agentContainerName))
		Expect(agent.Image).To(Equal("buildkite/agent:3.90.0"))
		Expect(agent.Command).To(BeEmpty())
		Expect(agent.Args).To(BeEmpty())
		Expect(agent.Ports).To(ContainElement(corev1.ContainerPort{
			Name: agentHealthPortName, ContainerPort: agentHealthPort, Protocol: corev1.ProtocolTCP,
		}))
		Expect(agent.ReadinessProbe.HTTPGet.Path).To(Equal("/agent/1"))
		Expect(agent.Env).To(ContainElements(
			corev1.EnvVar{Name: "BUILDKITE_AGENT_TAGS", Value: "queue=macos-arm64"},
			corev1.EnvVar{Name: "BUILDKITE_AGENT_HEALTH_CHECK_ADDR", Value: "0.0.0.0:8080"},
		))
		Expect(agent.Env).To(ContainElement(corev1.EnvVar{
			Name: "BUILDKITE_AGENT_TOKEN",
			ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{
				LocalObjectReference: corev1.LocalObjectReference{Name: agentTokenSecretName},
				Key:                  agentTokenSecretKey,
			}},
		}))

		pod = setPodStatus(pod, AgentStatusIdle, true)
		reconcileNow()
		status := currentPool().Status
		Expect(status.TotalRunners).To(BeEquivalentTo(1))
		Expect(status.IdleRunners).To(BeEquivalentTo(1))
		Expect(status.BusyRunners).To(BeZero())
		Expect(status.ReadyRunners).To(BeEquivalentTo(1))
		ready := meta.FindStatusCondition(status.Conditions, buildkitecomv1alpha1.RunnerPoolConditionReady)
		Expect(ready.Status).To(Equal(metav1.ConditionTrue))
		Expect(ready.Reason).To(Equal("AgentsReady"))
	})

	It("adds idle capacity as agents become busy and stops at maxRunners", func() {
		reconcileNow()
		pods := agentPods()
		setPodStatus(pods[0], AgentStatusBusy, true)

		reconcileNow()
		pods = agentPods()
		Expect(pods).To(HaveLen(2))
		for i := range pods {
			setPodStatus(pods[i], AgentStatusBusy, true)
		}

		reconcileNow()
		pods = agentPods()
		Expect(pods).To(HaveLen(3))
		for i := range pods {
			setPodStatus(pods[i], AgentStatusBusy, true)
		}

		reconcileNow()
		Expect(agentPods()).To(HaveLen(3))
		Expect(currentPool().Status.BusyRunners).To(BeEquivalentTo(3))
	})

	It("evicts only confirmed idle surplus after the timeout", func() {
		setPoolScaling(3, 1, 30)
		for range 3 {
			pod := createAgentPod()
			pod = setPodStatus(pod, AgentStatusIdle, true)
			setIdleSince(pod, time.Now())
		}

		reconcileNow()
		Expect(agentPods()).To(HaveLen(3))

		pods := agentPods()
		for i := range pods {
			setIdleSince(pods[i], time.Now().Add(-time.Minute))
		}
		reconcileNow()
		Expect(agentPods()).To(HaveLen(1))
	})

	It("does not treat warming, unreachable, or unready Pods as idle scale-down capacity", func() {
		setPoolScaling(4, 1, 0)
		idle := createAgentPod()
		idle = setPodStatus(idle, AgentStatusIdle, true)
		setIdleSince(idle, time.Now().Add(-time.Minute))
		createAgentPod()
		unreachable := createAgentPod()
		unreachable = setPodStatus(unreachable, AgentStatusIdle, true)
		checker.errors[unreachable.Status.PodIP] = errors.New("unreachable")
		unready := createAgentPod()
		setPodStatus(unready, AgentStatusIdle, false)

		reconcileNow()
		Expect(agentPods()).To(HaveLen(4))
		status := currentPool().Status
		Expect(status.TotalRunners).To(BeEquivalentTo(4))
		Expect(status.IdleRunners).To(BeEquivalentTo(1))
		Expect(status.BusyRunners).To(BeZero())
	})

	It("never evicts busy agents and resets their observed idle time", func() {
		setPoolScaling(3, 1, 0)
		busy := createAgentPod()
		busy = setPodStatus(busy, AgentStatusBusy, true)
		setIdleSince(busy, time.Now().Add(-time.Hour))
		for range 2 {
			idle := createAgentPod()
			idle = setPodStatus(idle, AgentStatusIdle, true)
			setIdleSince(idle, time.Now().Add(-time.Hour))
		}

		reconcileNow()
		pods := agentPods()
		Expect(pods).To(HaveLen(2))
		var foundBusy *corev1.Pod
		for i := range pods {
			if pods[i].Status.PodIP == busy.Status.PodIP {
				foundBusy = &pods[i]
			}
		}
		Expect(foundBusy).NotTo(BeNil())
		Expect(foundBusy.Annotations).NotTo(HaveKey(idleSinceAnnotation))
	})

	It("preserves an agent that becomes busy during the pre-delete check", func() {
		setPoolScaling(2, 1, 30)
		candidate := createAgentPod()
		candidate = setPodStatus(candidate, AgentStatusIdle, true)
		candidate = setIdleSince(candidate, time.Now().Add(-time.Minute))
		other := createAgentPod()
		other = setPodStatus(other, AgentStatusIdle, true)
		setIdleSince(other, time.Now())
		checker.responses[candidate.Status.PodIP] = []AgentStatus{AgentStatusIdle, AgentStatusBusy}

		reconcileNow()
		pods := agentPods()
		Expect(pods).To(HaveLen(2))
		candidateIndex := slices.IndexFunc(pods, func(pod corev1.Pod) bool {
			return pod.Name == candidate.Name
		})
		Expect(candidateIndex).To(BeNumerically(">=", 0))
		candidate = pods[candidateIndex]
		Expect(candidate.Annotations).NotTo(HaveKey(idleSinceAnnotation))
	})

	It("scales to zero and remains dormant when minIdleRunners is zero", func() {
		setPoolScaling(3, 0, 0)
		reconcileNow()
		reconcileNow()
		Expect(agentPods()).To(BeEmpty())

		ready := meta.FindStatusCondition(
			currentPool().Status.Conditions,
			buildkitecomv1alpha1.RunnerPoolConditionReady,
		)
		Expect(ready.Status).To(Equal(metav1.ConditionTrue))
		Expect(ready.Message).To(Equal("0 of 0 agents ready"))
	})

	It("rolls template changes by replacing only idle stale Pods", func() {
		reconcileNow()
		oldPod := setPodStatus(agentPods()[0], AgentStatusIdle, true)

		pool := currentPool()
		pool.Spec.Image = updatedAgentImage
		Expect(k8sClient.Update(ctx, pool)).To(Succeed())
		reconcileNow()

		pods := agentPods()
		Expect(pods).To(HaveLen(2))
		var newPod corev1.Pod
		for i := range pods {
			if pods[i].Name != oldPod.Name {
				newPod = setPodStatus(pods[i], AgentStatusIdle, true)
			}
		}
		Expect(newPod.Name).NotTo(BeEmpty())

		reconcileNow()
		pods = agentPods()
		Expect(pods).To(HaveLen(1))
		Expect(pods[0].Name).To(Equal(newPod.Name))
		Expect(pods[0].Spec.Containers[0].Image).To(Equal(updatedAgentImage))
	})

	It("keeps a busy stale Pod until its replacement buffer is sufficient", func() {
		reconcileNow()
		oldPod := setPodStatus(agentPods()[0], AgentStatusBusy, true)

		pool := currentPool()
		pool.Spec.Image = updatedAgentImage
		Expect(k8sClient.Update(ctx, pool)).To(Succeed())
		reconcileNow()

		pods := agentPods()
		Expect(pods).To(HaveLen(2))
		for i := range pods {
			if pods[i].Name != oldPod.Name {
				setPodStatus(pods[i], AgentStatusIdle, true)
			}
		}

		reconcileNow()
		Expect(agentPods()).To(HaveLen(2))

		checker.statuses[oldPod.Status.PodIP] = AgentStatusIdle
		reconcileNow()
		pods = agentPods()
		Expect(pods).To(HaveLen(1))
		Expect(pods[0].Name).NotTo(Equal(oldPod.Name))
	})

	It("honors the hard cap while replacing an idle stale Pod", func() {
		setPoolScaling(1, 1, 10)
		reconcileNow()
		oldPod := setPodStatus(agentPods()[0], AgentStatusIdle, true)

		pool := currentPool()
		pool.Spec.Image = updatedAgentImage
		Expect(k8sClient.Update(ctx, pool)).To(Succeed())
		reconcileNow()
		Expect(agentPods()).To(BeEmpty())

		reconcileNow()
		pods := agentPods()
		Expect(pods).To(HaveLen(1))
		Expect(pods[0].Name).NotTo(Equal(oldPod.Name))
		Expect(pods[0].Spec.Containers[0].Image).To(Equal(updatedAgentImage))
	})

	It("replaces terminal Pods", func() {
		reconcileNow()
		oldPod := agentPods()[0]
		current := &corev1.Pod{}
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(&oldPod), current)).To(Succeed())
		current.Status.Phase = corev1.PodFailed
		Expect(k8sClient.Status().Update(ctx, current)).To(Succeed())

		reconcileNow()
		pods := agentPods()
		Expect(pods).To(HaveLen(1))
		Expect(pods[0].Name).NotTo(Equal(oldPod.Name))
	})

	It("clears idle observations after a failed status check", func() {
		reconcileNow()
		setPodStatus(agentPods()[0], AgentStatusIdle, true)
		reconcileNow()
		pod := agentPods()[0]
		Expect(pod.Annotations).To(HaveKey(idleSinceAnnotation))

		checker.errors[pod.Status.PodIP] = errors.New("unreachable")
		reconcileNow()
		Expect(agentPods()[0].Annotations).NotTo(HaveKey(idleSinceAnnotation))
		Expect(currentPool().Status.IdleRunners).To(BeZero())
	})

	It("does not rewrite unchanged status", func() {
		reconcileNow()
		setPodStatus(agentPods()[0], AgentStatusIdle, true)
		reconcileNow()
		before := currentPool().ResourceVersion

		reconcileNow()
		reconcileNow()
		Expect(currentPool().ResourceVersion).To(Equal(before))
	})

	It("rejects minIdleRunners greater than maxRunners", func() {
		err := k8sClient.Create(ctx, &buildkitecomv1alpha1.RunnerPool{
			ObjectMeta: metav1.ObjectMeta{Name: "invalid-scaling", Namespace: namespace},
			Spec: buildkitecomv1alpha1.RunnerPoolSpec{
				Queue:          queueName,
				MaxRunners:     1,
				MinIdleRunners: ptrTo(int32(2)),
				AgentTokenSecretRef: corev1.SecretKeySelector{
					LocalObjectReference: corev1.LocalObjectReference{Name: agentTokenSecretName},
					Key:                  agentTokenSecretKey,
				},
			},
		})
		Expect(err).To(MatchError(ContainSubstring("minIdleRunners must be less than or equal to maxRunners")))
	})

	It("rejects a name too long to fit in a label value", func() {
		err := k8sClient.Create(ctx, &buildkitecomv1alpha1.RunnerPool{
			ObjectMeta: metav1.ObjectMeta{Name: strings.Repeat("a", 64), Namespace: namespace},
			Spec: buildkitecomv1alpha1.RunnerPoolSpec{
				Queue:      queueName,
				MaxRunners: 1,
				AgentTokenSecretRef: corev1.SecretKeySelector{
					LocalObjectReference: corev1.LocalObjectReference{Name: agentTokenSecretName},
					Key:                  agentTokenSecretKey,
				},
			},
		})
		Expect(err).To(MatchError(ContainSubstring("63 characters")))
	})

	It("rejects resources.claims", func() {
		err := k8sClient.Create(ctx, &buildkitecomv1alpha1.RunnerPool{
			ObjectMeta: metav1.ObjectMeta{Name: "with-claims", Namespace: namespace},
			Spec: buildkitecomv1alpha1.RunnerPoolSpec{
				Queue:      queueName,
				MaxRunners: 1,
				AgentTokenSecretRef: corev1.SecretKeySelector{
					LocalObjectReference: corev1.LocalObjectReference{Name: agentTokenSecretName},
					Key:                  agentTokenSecretKey,
				},
				Resources: corev1.ResourceRequirements{
					Claims: []corev1.ResourceClaim{{Name: "gpu"}},
				},
			},
		})
		Expect(err).To(MatchError(ContainSubstring("resources.claims is not supported")))
	})

	It("ignores a pool that no longer exists", func() {
		pool := currentPool()
		Expect(k8sClient.Delete(ctx, pool)).To(Succeed())
		_, err := reconciler.Reconcile(ctx, reconcile.Request{NamespacedName: poolKey})
		Expect(err).NotTo(HaveOccurred())
	})
})

var _ = Describe("HTTPAgentStatusChecker", func() {
	It("reads and validates aggregate status", func() {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			_, _ = w.Write([]byte(`{"health":"ok","aggregate_status":"busy"}`))
		}))
		DeferCleanup(server.Close)

		parsed, err := url.Parse(server.URL)
		Expect(err).NotTo(HaveOccurred())
		host, portString, err := net.SplitHostPort(parsed.Host)
		Expect(err).NotTo(HaveOccurred())
		port, err := strconv.Atoi(portString)
		Expect(err).NotTo(HaveOccurred())

		checker := &HTTPAgentStatusChecker{Client: server.Client()}
		status, err := checker.Check(context.Background(), host, int32(port))
		Expect(err).NotTo(HaveOccurred())
		Expect(status).To(Equal(AgentStatusBusy))
	})

	It("rejects unknown aggregate status", func() {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			_, _ = w.Write([]byte(`{"aggregate_status":"draining"}`))
		}))
		DeferCleanup(server.Close)

		parsed, err := url.Parse(server.URL)
		Expect(err).NotTo(HaveOccurred())
		host, portString, err := net.SplitHostPort(parsed.Host)
		Expect(err).NotTo(HaveOccurred())
		port, err := strconv.Atoi(portString)
		Expect(err).NotTo(HaveOccurred())

		checker := &HTTPAgentStatusChecker{Client: server.Client()}
		_, err = checker.Check(context.Background(), host, int32(port))
		Expect(err).To(MatchError(ContainSubstring("unknown aggregate status")))
	})
})

func ptrTo[T any](value T) *T { return &value }
