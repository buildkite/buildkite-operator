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
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/rand"
	ctrl "sigs.k8s.io/controller-runtime"
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
		agentImage           = "buildkite/agent:3.90.0"
		updatedAgentImage    = "buildkite/agent:3.100.0"
		registrySecretName   = "registry-credentials"
		runnerNodeLabel      = "buildkite.com/runner"
		runnerNodeValue      = "true"
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

	// startDraining begins deletion of pod while keeping it around, standing
	// in for a kubelet that has not yet finished stopping the agent. envtest
	// has no scheduler, so unscheduled Pods are otherwise deleted immediately;
	// a finalizer reproduces the same lingering-Terminating-Pod semantics
	// portably.
	const testFinalizer = "buildkite.com/test-drain"
	startDraining := func(pod corev1.Pod) corev1.Pod {
		GinkgoHelper()
		current := &corev1.Pod{}
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(&pod), current)).To(Succeed())
		current.Finalizers = append(current.Finalizers, testFinalizer)
		Expect(k8sClient.Update(ctx, current)).To(Succeed())
		Expect(k8sClient.Delete(ctx, current)).To(Succeed())
		Expect(k8sClient.Get(ctx, client.ObjectKeyFromObject(&pod), current)).To(Succeed())
		return *current
	}

	// finalizeTerminatingPods simulates the kubelet finishing termination by
	// removing the finalizer, letting Kubernetes complete the deletion.
	finalizeTerminatingPods := func() {
		GinkgoHelper()
		list := &corev1.PodList{}
		Expect(k8sClient.List(ctx, list,
			client.InNamespace(namespace),
			client.MatchingLabels{poolLabel: poolName},
		)).To(Succeed())
		for i := range list.Items {
			pod := &list.Items[i]
			if pod.DeletionTimestamp.IsZero() {
				continue
			}
			pod.Finalizers = slices.DeleteFunc(pod.Finalizers, func(f string) bool { return f == testFinalizer })
			Expect(k8sClient.Update(ctx, pod)).To(Succeed())
		}
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
				AgentImage: agentImage,
				AgentTokenSecretRef: corev1.SecretKeySelector{
					LocalObjectReference: corev1.LocalObjectReference{Name: agentTokenSecretName},
					Key:                  agentTokenSecretKey,
				},
			},
		})).To(Succeed())
	})

	It("creates directly owned Docker Pods with health checks and graceful termination", func() {
		pool := currentPool()
		Expect(pool.Spec.Docker).NotTo(BeNil())
		Expect(pool.Spec.Docker.DaemonImage).To(Equal(defaultDaemonImage))
		Expect(pool.Spec.Docker.SupervisorImage).To(Equal(defaultSupervisorImage))

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
		Expect(pod.Spec.AutomountServiceAccountToken).To(HaveValue(BeFalse()))
		Expect(pod.Spec.SecurityContext.FSGroup).To(HaveValue(Equal(dockerGroupID)))
		Expect(pod.Spec.SecurityContext.SupplementalGroups).To(ContainElement(dockerGroupID))
		Expect(pod.Spec.Volumes).To(HaveLen(3))
		Expect(volumeByName(pod.Spec.Volumes, dockerDataVolumeName).EmptyDir).NotTo(BeNil())
		Expect(volumeByName(pod.Spec.Volumes, dockerRunVolumeName).EmptyDir).NotTo(BeNil())
		Expect(volumeByName(pod.Spec.Volumes, workspaceVolumeName).EmptyDir).NotTo(BeNil())

		Expect(pod.Spec.InitContainers).To(HaveLen(1))
		dockerd := containerByName(pod.Spec.InitContainers, dockerdContainerName)
		Expect(dockerd.Image).To(Equal(defaultDaemonImage))
		Expect(dockerd.Command).To(Equal([]string{"/usr/local/bin/dockerd-entrypoint.sh"}))
		Expect(dockerd.Args).To(Equal([]string{
			"dockerd", "--host=unix:///var/run/docker.sock", "--group=2375",
		}))
		Expect(dockerd.RestartPolicy).To(HaveValue(Equal(corev1.ContainerRestartPolicyAlways)))
		Expect(dockerd.SecurityContext.Privileged).To(HaveValue(BeTrue()))
		Expect(dockerd.SecurityContext.RunAsUser).To(HaveValue(BeZero()))
		Expect(dockerd.StartupProbe).NotTo(BeNil())
		Expect(dockerd.ReadinessProbe).NotTo(BeNil())
		Expect(dockerd.LivenessProbe).To(BeNil())
		Expect(dockerd.VolumeMounts).To(ContainElements(
			corev1.VolumeMount{Name: dockerDataVolumeName, MountPath: "/var/lib/docker"},
			corev1.VolumeMount{Name: dockerRunVolumeName, MountPath: dockerRunPath},
			corev1.VolumeMount{Name: workspaceVolumeName, MountPath: "/workspace"},
		))

		Expect(pod.Spec.Containers).To(HaveLen(1))
		supervisor := containerByName(pod.Spec.Containers, supervisorContainerName)
		Expect(supervisor.Image).To(Equal(defaultSupervisorImage))
		Expect(supervisor.Command).To(HaveLen(3))
		Expect(supervisor.Command[:2]).To(Equal([]string{shellPath, "-c"}))
		Expect(supervisor.Command[2]).To(ContainSubstring("docker wait \"$agent_name\" >/dev/null 2>&1 &"))
		Expect(supervisor.Command[2]).To(ContainSubstring("--publish 8080:8080"))
		Expect(supervisor.Ports).To(ContainElement(corev1.ContainerPort{
			Name: agentHealthPortName, ContainerPort: agentHealthPort, Protocol: corev1.ProtocolTCP,
		}))
		Expect(supervisor.ReadinessProbe.HTTPGet.Path).To(Equal("/agent/1"))
		Expect(supervisor.LivenessProbe).To(BeNil())
		Expect(supervisor.SecurityContext.RunAsUser).To(HaveValue(Equal(supervisorUID)))
		Expect(supervisor.SecurityContext.RunAsGroup).To(HaveValue(Equal(dockerGroupID)))
		Expect(supervisor.SecurityContext.RunAsNonRoot).To(HaveValue(BeTrue()))
		Expect(supervisor.SecurityContext.AllowPrivilegeEscalation).To(HaveValue(BeFalse()))
		Expect(supervisor.SecurityContext.Capabilities.Drop).To(Equal([]corev1.Capability{"ALL"}))
		Expect(supervisor.Resources.Requests).To(Equal(corev1.ResourceList{
			corev1.ResourceCPU:    resource.MustParse("10m"),
			corev1.ResourceMemory: resource.MustParse("32Mi"),
		}))
		Expect(supervisor.Resources.Limits).To(Equal(corev1.ResourceList{
			corev1.ResourceCPU:    resource.MustParse("100m"),
			corev1.ResourceMemory: resource.MustParse("128Mi"),
		}))
		Expect(supervisor.Env).To(ContainElements(
			corev1.EnvVar{Name: agentImageEnvName, Value: agentImage},
			corev1.EnvVar{Name: "AGENT_TAGS", Value: "queue=macos-arm64"},
			corev1.EnvVar{Name: "TERMINATION_GRACE_PERIOD_SECONDS", Value: "3600"},
			corev1.EnvVar{Name: dockerHostEnvName, Value: dockerHost},
		))
		Expect(supervisor.Env).To(ContainElement(corev1.EnvVar{
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

	It("applies Docker credentials, resources, and scheduling settings to new Pods", func() {
		pool := currentPool()
		pool.Spec.Docker = &buildkitecomv1alpha1.RunnerPoolDockerSpec{
			DaemonImage:     "registry.example.test/docker:dind",
			SupervisorImage: "registry.example.test/docker:cli",
			ConfigSecretRef: &corev1.LocalObjectReference{Name: registrySecretName},
		}
		pool.Spec.Resources = corev1.ResourceRequirements{
			Requests: corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("2")},
			Limits:   corev1.ResourceList{corev1.ResourceCPU: resource.MustParse("4")},
		}
		pool.Spec.TerminationGracePeriodSeconds = ptrTo(int64(45))
		pool.Spec.NodeSelector = map[string]string{runnerNodeLabel: runnerNodeValue}
		pool.Spec.Tolerations = []corev1.Toleration{{
			Key: runnerNodeLabel, Operator: corev1.TolerationOpEqual,
			Value: runnerNodeValue, Effect: corev1.TaintEffectNoSchedule,
		}}
		Expect(k8sClient.Update(ctx, pool)).To(Succeed())

		reconcileNow()
		pod := agentPods()[0]
		dockerd := containerByName(pod.Spec.InitContainers, dockerdContainerName)
		supervisor := containerByName(pod.Spec.Containers, supervisorContainerName)

		Expect(dockerd.Image).To(Equal("registry.example.test/docker:dind"))
		Expect(supervisor.Image).To(Equal("registry.example.test/docker:cli"))
		Expect(dockerd.Resources.Requests.Cpu().String()).To(Equal("2"))
		Expect(dockerd.Resources.Limits.Cpu().String()).To(Equal("4"))
		Expect(pod.Spec.TerminationGracePeriodSeconds).To(HaveValue(Equal(int64(45))))
		Expect(pod.Spec.NodeSelector).To(Equal(map[string]string{runnerNodeLabel: runnerNodeValue}))
		Expect(pod.Spec.Tolerations).To(ContainElement(pool.Spec.Tolerations[0]))
		Expect(pod.Spec.ImagePullSecrets).To(Equal([]corev1.LocalObjectReference{{Name: registrySecretName}}))

		configVolume := volumeByName(pod.Spec.Volumes, dockerConfigVolumeName)
		Expect(configVolume.Secret.SecretName).To(Equal(registrySecretName))
		Expect(configVolume.Secret.Items).To(Equal([]corev1.KeyToPath{{
			Key: corev1.DockerConfigJsonKey, Path: "config.json",
		}}))
		Expect(dockerd.VolumeMounts).To(ContainElement(corev1.VolumeMount{
			Name: dockerConfigVolumeName, MountPath: dockerConfigPath, ReadOnly: true,
		}))
		Expect(supervisor.VolumeMounts).To(ContainElement(corev1.VolumeMount{
			Name: dockerConfigVolumeName, MountPath: dockerConfigPath, ReadOnly: true,
		}))
		Expect(supervisor.Env).To(ContainElement(corev1.EnvVar{Name: "DOCKER_CONFIG", Value: dockerConfigPath}))

		configuredHash, err := desiredPodTemplateHash(pool)
		Expect(err).NotTo(HaveOccurred())
		pool.Spec.Docker.ConfigSecretRef = nil
		pool.Spec.Resources = corev1.ResourceRequirements{}
		pool.Spec.NodeSelector = nil
		pool.Spec.Tolerations = nil
		clearedHash, err := desiredPodTemplateHash(pool)
		Expect(err).NotTo(HaveOccurred())
		Expect(clearedHash).NotTo(Equal(configuredHash))
		cleared := desiredAgentPodSpec(pool)
		Expect(cleared.ImagePullSecrets).To(BeEmpty())
		Expect(cleared.NodeSelector).To(BeEmpty())
		Expect(cleared.Tolerations).To(BeEmpty())
		Expect(cleared.Volumes).NotTo(ContainElement(HaveField("Name", dockerConfigVolumeName)))
		Expect(containerByName(cleared.InitContainers, dockerdContainerName).Resources).To(BeZero())
		Expect(containerByName(cleared.Containers, supervisorContainerName).Env).
			NotTo(ContainElement(HaveField("Name", "DOCKER_CONFIG")))
	})

	It("rolls directly run legacy agents into supervised Docker Pods", func() {
		pool := currentPool()
		legacy := &corev1.Pod{
			ObjectMeta: metav1.ObjectMeta{
				Name:      poolName + "-legacy",
				Namespace: namespace,
				Labels:    poolLabels(pool),
				Annotations: map[string]string{
					podTemplateHashAnnotation: "legacy-template",
				},
			},
			Spec: corev1.PodSpec{Containers: []corev1.Container{{
				Name: "agent", Image: agentImage,
			}}},
		}
		Expect(ctrl.SetControllerReference(pool, legacy, k8sClient.Scheme())).To(Succeed())
		Expect(k8sClient.Create(ctx, legacy)).To(Succeed())
		legacyPod := setPodStatus(*legacy, AgentStatusIdle, true)

		reconcileNow()
		pods := agentPods()
		Expect(pods).To(HaveLen(2))
		newIndex := slices.IndexFunc(pods, func(pod corev1.Pod) bool { return pod.Name != legacyPod.Name })
		Expect(newIndex).To(BeNumerically(">=", 0))
		newPod := setPodStatus(pods[newIndex], AgentStatusIdle, true)
		Expect(containerByName(newPod.Spec.Containers, supervisorContainerName).Name).To(Equal(supervisorContainerName))

		reconcileNow()
		pods = agentPods()
		Expect(pods).To(HaveLen(1))
		Expect(pods[0].Name).To(Equal(newPod.Name))
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
		pool.Spec.AgentImage = updatedAgentImage
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
		Expect(containerByName(pods[0].Spec.Containers, supervisorContainerName).Env).
			To(ContainElement(corev1.EnvVar{Name: agentImageEnvName, Value: updatedAgentImage}))
	})

	It("keeps a busy stale Pod until its replacement buffer is sufficient", func() {
		reconcileNow()
		oldPod := setPodStatus(agentPods()[0], AgentStatusBusy, true)

		pool := currentPool()
		pool.Spec.AgentImage = updatedAgentImage
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
		pool.Spec.AgentImage = updatedAgentImage
		Expect(k8sClient.Update(ctx, pool)).To(Succeed())
		reconcileNow()
		Expect(agentPods()).To(BeEmpty())

		reconcileNow()
		pods := agentPods()
		Expect(pods).To(HaveLen(1))
		Expect(pods[0].Name).NotTo(Equal(oldPod.Name))
		Expect(containerByName(pods[0].Spec.Containers, supervisorContainerName).Env).
			To(ContainElement(corev1.EnvVar{Name: agentImageEnvName, Value: updatedAgentImage}))
	})

	It("counts a draining Pod against maxRunners until it actually disappears", func() {
		setPoolScaling(1, 1, 0)
		reconcileNow()
		pod := setPodStatus(agentPods()[0], AgentStatusIdle, true)
		setIdleSince(pod, time.Now())
		pod = startDraining(pod)
		Expect(pod.DeletionTimestamp).NotTo(BeNil())

		reconcileNow()
		Expect(agentPods()).To(BeEmpty())
		status := currentPool().Status
		Expect(status.TotalRunners).To(BeZero())

		finalizeTerminatingPods()
		reconcileNow()
		Expect(agentPods()).To(HaveLen(1))
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

func containerByName(containers []corev1.Container, name string) corev1.Container {
	GinkgoHelper()
	for _, container := range containers {
		if container.Name == name {
			return container
		}
	}
	Fail(fmt.Sprintf("container %q not found", name))
	return corev1.Container{}
}

func volumeByName(volumes []corev1.Volume, name string) corev1.Volume {
	GinkgoHelper()
	for _, volume := range volumes {
		if volume.Name == name {
			return volume
		}
	}
	Fail(fmt.Sprintf("volume %q not found", name))
	return corev1.Volume{}
}
