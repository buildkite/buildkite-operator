// Copyright (c) 2026 Buildkite Pty Ltd
// SPDX-License-Identifier: MIT

package controller

import (
	"context"
	"fmt"
	"strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/rand"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	buildkitecomv1alpha1 "github.com/buildkite/buildkite-operator/api/v1alpha1"
)

var _ = Describe("RunnerPool Controller", func() {
	const (
		poolName             = "test-pool"
		queueName            = "macos-arm64"
		agentTokenSecretName = "buildkite-agent-token"
		agentTokenSecretKey  = "token"
	)

	var (
		ctx        context.Context
		namespace  string
		reconciler *RunnerPoolReconciler
		poolKey    types.NamespacedName
		deployKey  types.NamespacedName
	)

	// reconcileNow runs a single reconcile for the pool under test.
	reconcileNow := func() {
		GinkgoHelper()
		_, err := reconciler.Reconcile(ctx, reconcile.Request{NamespacedName: poolKey})
		Expect(err).NotTo(HaveOccurred())
	}

	// deployment fetches the Deployment the pool is expected to own.
	deployment := func() *appsv1.Deployment {
		GinkgoHelper()
		deploy := &appsv1.Deployment{}
		Expect(k8sClient.Get(ctx, deployKey, deploy)).To(Succeed())
		return deploy
	}

	BeforeEach(func() {
		ctx = context.Background()
		reconciler = &RunnerPoolReconciler{Client: k8sClient, Scheme: k8sClient.Scheme()}

		// Each spec gets its own namespace so pools cannot interfere.
		namespace = fmt.Sprintf("runnerpool-%s", rand.String(8))
		Expect(k8sClient.Create(ctx, &corev1.Namespace{
			ObjectMeta: metav1.ObjectMeta{Name: namespace},
		})).To(Succeed())

		poolKey = types.NamespacedName{Name: poolName, Namespace: namespace}
		deployKey = types.NamespacedName{Name: poolName + "-agent", Namespace: namespace}

		By("creating a RunnerPool")
		Expect(k8sClient.Create(ctx, &buildkitecomv1alpha1.RunnerPool{
			ObjectMeta: metav1.ObjectMeta{Name: poolName, Namespace: namespace},
			Spec: buildkitecomv1alpha1.RunnerPoolSpec{
				Queue: queueName,
				Image: "buildkite/agent:3.90.0",
				AgentTokenSecretRef: corev1.SecretKeySelector{
					LocalObjectReference: corev1.LocalObjectReference{Name: agentTokenSecretName},
					Key:                  agentTokenSecretKey,
				},
			},
		})).To(Succeed())
	})

	It("creates a Deployment of agents owned by the pool", func() {
		reconcileNow()

		deploy := deployment()

		By("using the pool's replica count, defaulted by the CRD")
		Expect(deploy.Spec.Replicas).To(HaveValue(BeEquivalentTo(1)))

		By("running the pool's agent image with no command override")
		Expect(deploy.Spec.Template.Spec.Containers).To(HaveLen(1))
		agent := deploy.Spec.Template.Spec.Containers[0]
		Expect(agent.Name).To(Equal("agent"))
		Expect(agent.Image).To(Equal("buildkite/agent:3.90.0"))
		Expect(agent.Command).To(BeEmpty())
		Expect(agent.Args).To(BeEmpty())

		By("passing the agent token by reference and tagging with the queue")
		Expect(agent.Env).To(ContainElement(corev1.EnvVar{
			Name: "BUILDKITE_AGENT_TOKEN",
			ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{
				LocalObjectReference: corev1.LocalObjectReference{Name: agentTokenSecretName},
				Key:                  agentTokenSecretKey,
			}},
		}))
		Expect(agent.Env).To(ContainElement(corev1.EnvVar{
			Name:  "BUILDKITE_AGENT_TAGS",
			Value: "queue=macos-arm64",
		}))

		By("selecting its pods by name and instance")
		Expect(deploy.Spec.Selector.MatchLabels).To(Equal(map[string]string{
			"app.kubernetes.io/name":     "buildkite-agent",
			"app.kubernetes.io/instance": poolName,
		}))
		Expect(deploy.Spec.Template.Labels).To(HaveKeyWithValue("buildkite.com/runner-pool", poolName))

		By("setting a controller owner reference so the Deployment is garbage collected")
		Expect(deploy.OwnerReferences).To(HaveLen(1))
		owner := deploy.OwnerReferences[0]
		Expect(owner.Kind).To(Equal("RunnerPool"))
		Expect(owner.Name).To(Equal(poolName))
		Expect(owner.Controller).To(HaveValue(BeTrue()))
	})

	It("updates the Deployment when the pool's replicas change", func() {
		reconcileNow()
		Expect(deployment().Spec.Replicas).To(HaveValue(BeEquivalentTo(1)))

		pool := &buildkitecomv1alpha1.RunnerPool{}
		Expect(k8sClient.Get(ctx, poolKey, pool)).To(Succeed())
		pool.Spec.Replicas = ptrTo(int32(4))
		Expect(k8sClient.Update(ctx, pool)).To(Succeed())

		reconcileNow()
		Expect(deployment().Spec.Replicas).To(HaveValue(BeEquivalentTo(4)))
	})

	It("reverts changes made to the Deployment behind the operator's back", func() {
		reconcileNow()

		deploy := deployment()
		deploy.Spec.Replicas = ptrTo(int32(9))
		deploy.Spec.Template.Spec.Containers[0].Image = "nginx:latest"
		Expect(k8sClient.Update(ctx, deploy)).To(Succeed())

		reconcileNow()

		deploy = deployment()
		Expect(deploy.Spec.Replicas).To(HaveValue(BeEquivalentTo(1)))
		Expect(deploy.Spec.Template.Spec.Containers[0].Image).To(Equal("buildkite/agent:3.90.0"))
	})

	It("does not rewrite the Deployment when nothing has changed", func() {
		// A reconcile that always issues an update would trigger its own next
		// reconcile via the Owns() watch, spinning the controller forever.
		reconcileNow()
		before := deployment().ResourceVersion

		reconcileNow()
		reconcileNow()

		Expect(deployment().ResourceVersion).To(Equal(before))
	})

	Describe("status", func() {
		// envtest runs no Deployment controller, so the Deployment's status is
		// whatever this test writes to it.
		setDeploymentStatus := func(ready int32, available corev1.ConditionStatus, reason, message string) {
			GinkgoHelper()
			deploy := deployment()
			deploy.Status.Replicas = ready
			deploy.Status.ReadyReplicas = ready
			// envtest runs no Deployment controller, so simulate one that has
			// observed the current spec; otherwise the pool holds Ready at
			// Unknown while observedGeneration lags the generation.
			deploy.Status.ObservedGeneration = deploy.Generation
			deploy.Status.Conditions = []appsv1.DeploymentCondition{{
				Type:               appsv1.DeploymentAvailable,
				Status:             available,
				Reason:             reason,
				Message:            message,
				LastTransitionTime: metav1.Now(),
			}}
			Expect(k8sClient.Status().Update(ctx, deploy)).To(Succeed())
		}

		pool := func() *buildkitecomv1alpha1.RunnerPool {
			GinkgoHelper()
			p := &buildkitecomv1alpha1.RunnerPool{}
			Expect(k8sClient.Get(ctx, poolKey, p)).To(Succeed())
			return p
		}

		It("reports Ready as unknown until the Deployment says anything", func() {
			reconcileNow()

			// Mark the Deployment as having observed its current spec but not
			// yet reporting any condition, isolating the pending-availability
			// path from the generation-mismatch guard.
			deploy := deployment()
			deploy.Status.ObservedGeneration = deploy.Generation
			Expect(k8sClient.Status().Update(ctx, deploy)).To(Succeed())
			reconcileNow()

			ready := meta.FindStatusCondition(pool().Status.Conditions, buildkitecomv1alpha1.RunnerPoolConditionReady)
			Expect(ready).NotTo(BeNil())
			Expect(ready.Status).To(Equal(metav1.ConditionUnknown))
			Expect(ready.Reason).To(Equal("DeploymentPending"))
		})

		It("reports Ready as unknown while the Deployment's status is stale", func() {
			// A Deployment whose template was just updated still carries the
			// previous rollout's Available=True until its controller observes
			// the new generation. That stale condition must not be copied
			// through as a current-generation Ready=True.
			reconcileNow()
			setDeploymentStatus(1, corev1.ConditionTrue, "MinimumReplicasAvailable", "")
			reconcileNow()

			deploy := deployment()
			deploy.Status.ObservedGeneration = deploy.Generation - 1
			Expect(k8sClient.Status().Update(ctx, deploy)).To(Succeed())
			reconcileNow()

			ready := meta.FindStatusCondition(pool().Status.Conditions, buildkitecomv1alpha1.RunnerPoolConditionReady)
			Expect(ready).NotTo(BeNil())
			Expect(ready.Status).To(Equal(metav1.ConditionUnknown))
			Expect(ready.Reason).To(Equal("DeploymentProgressing"))
		})

		It("becomes Ready with the Deployment's ready replica count", func() {
			reconcileNow()
			setDeploymentStatus(1, corev1.ConditionTrue, "MinimumReplicasAvailable", "")
			reconcileNow()

			status := pool().Status
			Expect(status.ReadyReplicas).To(BeEquivalentTo(1))
			Expect(status.ObservedGeneration).To(Equal(pool().Generation))

			ready := meta.FindStatusCondition(status.Conditions, buildkitecomv1alpha1.RunnerPoolConditionReady)
			Expect(ready.Status).To(Equal(metav1.ConditionTrue))
			Expect(ready.Reason).To(Equal("AgentsAvailable"))
			Expect(ready.Message).To(Equal("1 of 1 agents ready"))
		})

		It("becomes not Ready, surfacing the Deployment's reason", func() {
			reconcileNow()
			setDeploymentStatus(0, corev1.ConditionFalse, "MinimumReplicasUnavailable", "Deployment does not have minimum availability.")
			reconcileNow()

			status := pool().Status
			Expect(status.ReadyReplicas).To(BeZero())

			ready := meta.FindStatusCondition(status.Conditions, buildkitecomv1alpha1.RunnerPoolConditionReady)
			Expect(ready.Status).To(Equal(metav1.ConditionFalse))
			Expect(ready.Reason).To(Equal("MinimumReplicasUnavailable"))
			Expect(ready.Message).To(Equal("Deployment does not have minimum availability."))
		})

		It("does not rewrite an unchanged status", func() {
			// Status writes wake the controller through its own watch, so an
			// unconditional update would spin.
			reconcileNow()
			setDeploymentStatus(1, corev1.ConditionTrue, "MinimumReplicasAvailable", "")
			reconcileNow()
			before := pool().ResourceVersion

			reconcileNow()
			reconcileNow()

			Expect(pool().ResourceVersion).To(Equal(before))
		})
	})

	It("rejects a name too long to fit in a label value", func() {
		// Label values are capped at 63 characters, and pool.Name is copied
		// into both the selector and pool labels, so a longer name could
		// never be reconciled.
		tooLong := strings.Repeat("a", 64)
		err := k8sClient.Create(ctx, &buildkitecomv1alpha1.RunnerPool{
			ObjectMeta: metav1.ObjectMeta{Name: tooLong, Namespace: namespace},
			Spec: buildkitecomv1alpha1.RunnerPoolSpec{
				Queue: queueName,
				AgentTokenSecretRef: corev1.SecretKeySelector{
					LocalObjectReference: corev1.LocalObjectReference{Name: agentTokenSecretName},
					Key:                  agentTokenSecretKey,
				},
			},
		})
		Expect(err).To(HaveOccurred())
		Expect(err.Error()).To(ContainSubstring("63 characters"))
	})

	It("rejects resources.claims", func() {
		// The controller copies resources onto the agent container but never
		// models the corresponding pod-level spec.resourceClaims, so a
		// container claim would reference nothing and the Deployment would be
		// rejected. Disallow claims at admission instead.
		err := k8sClient.Create(ctx, &buildkitecomv1alpha1.RunnerPool{
			ObjectMeta: metav1.ObjectMeta{Name: "with-claims", Namespace: namespace},
			Spec: buildkitecomv1alpha1.RunnerPoolSpec{
				Queue: queueName,
				AgentTokenSecretRef: corev1.SecretKeySelector{
					LocalObjectReference: corev1.LocalObjectReference{Name: agentTokenSecretName},
					Key:                  agentTokenSecretKey,
				},
				Resources: corev1.ResourceRequirements{
					Claims: []corev1.ResourceClaim{{Name: "gpu"}},
				},
			},
		})
		Expect(err).To(HaveOccurred())
		Expect(err.Error()).To(ContainSubstring("resources.claims is not supported"))
	})

	It("ignores a pool that no longer exists", func() {
		pool := &buildkitecomv1alpha1.RunnerPool{}
		Expect(k8sClient.Get(ctx, poolKey, pool)).To(Succeed())
		Expect(k8sClient.Delete(ctx, pool)).To(Succeed())

		reconcileNow()

		Expect(k8sClient.Get(ctx, deployKey, &appsv1.Deployment{})).NotTo(Succeed())
	})
})

func ptrTo[T any](v T) *T { return &v }
