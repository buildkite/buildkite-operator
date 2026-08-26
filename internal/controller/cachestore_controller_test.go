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
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/rand"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	buildkitecomv1alpha1 "github.com/buildkite/buildkite-operator/api/v1alpha1"
)

var _ = Describe("CacheStore Controller", func() {
	const (
		storeName       = "build-cache"
		rpcSecretName   = "garage-rpc"
		rpcSecretKey    = "rpc-secret"
		credentialsName = "garage-credentials"
		accessKeyIDKey  = "access-key-id"
		secretKeyKey    = "secret-access-key"
	)

	var (
		ctx        context.Context
		namespace  string
		reconciler *CacheStoreReconciler
		storeKey   types.NamespacedName
	)

	newStore := func(name string) *buildkitecomv1alpha1.CacheStore {
		return &buildkitecomv1alpha1.CacheStore{
			ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: namespace},
			Spec: buildkitecomv1alpha1.CacheStoreSpec{
				RPCSecretRef: buildkitecomv1alpha1.CacheStoreRPCSecretReference{
					Name: rpcSecretName,
					Key:  rpcSecretKey,
				},
				CredentialsSecretRef: buildkitecomv1alpha1.CacheStoreCredentialsSecretReference{
					Name:               credentialsName,
					AccessKeyIDKey:     accessKeyIDKey,
					SecretAccessKeyKey: secretKeyKey,
				},
				Storage: buildkitecomv1alpha1.CacheStoreStorage{
					Size: resource.MustParse("2Gi"),
				},
			},
		}
	}

	createSecrets := func() {
		GinkgoHelper()
		immutable := true
		Expect(k8sClient.Create(ctx, &corev1.Secret{
			ObjectMeta: metav1.ObjectMeta{Name: rpcSecretName, Namespace: namespace},
			Immutable:  &immutable,
			Data:       map[string][]byte{rpcSecretKey: []byte(strings.Repeat("a", 64))},
		})).To(Succeed())
		Expect(k8sClient.Create(ctx, &corev1.Secret{
			ObjectMeta: metav1.ObjectMeta{Name: credentialsName, Namespace: namespace},
			Immutable:  &immutable,
			Data: map[string][]byte{
				accessKeyIDKey: []byte("GK0123456789abcdef"),
				secretKeyKey:   []byte("0123456789abcdef0123456789abcdef"),
			},
		})).To(Succeed())
	}

	createStore := func() *buildkitecomv1alpha1.CacheStore {
		GinkgoHelper()
		store := newStore(storeName)
		Expect(k8sClient.Create(ctx, store)).To(Succeed())
		return store
	}

	reconcileNow := func() {
		GinkgoHelper()
		_, err := reconciler.Reconcile(ctx, reconcile.Request{NamespacedName: storeKey})
		Expect(err).NotTo(HaveOccurred())
	}

	store := func() *buildkitecomv1alpha1.CacheStore {
		GinkgoHelper()
		result := &buildkitecomv1alpha1.CacheStore{}
		Expect(k8sClient.Get(ctx, storeKey, result)).To(Succeed())
		return result
	}

	statefulSet := func() *appsv1.StatefulSet {
		GinkgoHelper()
		result := &appsv1.StatefulSet{}
		Expect(k8sClient.Get(ctx, storeKey, result)).To(Succeed())
		return result
	}

	lifecycleJobs := func() []batchv1.Job {
		GinkgoHelper()
		result := &batchv1.JobList{}
		Expect(k8sClient.List(ctx, result, client.InNamespace(namespace), client.MatchingLabels{
			cacheStoreLabel: storeName,
		})).To(Succeed())
		return result.Items
	}

	BeforeEach(func() {
		ctx = context.Background()
		reconciler = &CacheStoreReconciler{Client: k8sClient, Scheme: k8sClient.Scheme()}
		namespace = fmt.Sprintf("cachestore-%s", rand.String(8))
		Expect(k8sClient.Create(ctx, &corev1.Namespace{
			ObjectMeta: metav1.ObjectMeta{Name: namespace},
		})).To(Succeed())
		storeKey = types.NamespacedName{Name: storeName, Namespace: namespace}
	})

	It("reports a missing RPC Secret without creating workloads", func() {
		createStore()
		reconcileNow()

		ready := meta.FindStatusCondition(store().Status.Conditions,
			buildkitecomv1alpha1.CacheStoreConditionReady)
		Expect(ready).NotTo(BeNil())
		Expect(ready.Status).To(Equal(metav1.ConditionFalse))
		Expect(ready.Reason).To(Equal("RPCSecretNotFound"))
		Expect(k8sClient.Get(ctx, storeKey, &appsv1.StatefulSet{})).NotTo(Succeed())
	})

	It("rejects mutable and malformed Secrets in status", func() {
		immutable := false
		Expect(k8sClient.Create(ctx, &corev1.Secret{
			ObjectMeta: metav1.ObjectMeta{Name: rpcSecretName, Namespace: namespace},
			Immutable:  &immutable,
			Data:       map[string][]byte{rpcSecretKey: []byte(strings.Repeat("a", 64))},
		})).To(Succeed())
		createStore()
		reconcileNow()
		ready := meta.FindStatusCondition(store().Status.Conditions,
			buildkitecomv1alpha1.CacheStoreConditionReady)
		Expect(ready.Reason).To(Equal("RPCSecretInvalid"))
		Expect(ready.Message).To(ContainSubstring("must be immutable"))

		By("validating the access-key ID after the RPC Secret is fixed")
		Expect(k8sClient.Delete(ctx, &corev1.Secret{
			ObjectMeta: metav1.ObjectMeta{Name: rpcSecretName, Namespace: namespace},
		})).To(Succeed())
		immutable = true
		Expect(k8sClient.Create(ctx, &corev1.Secret{
			ObjectMeta: metav1.ObjectMeta{Name: rpcSecretName, Namespace: namespace},
			Immutable:  &immutable,
			Data:       map[string][]byte{rpcSecretKey: []byte(strings.Repeat("b", 64))},
		})).To(Succeed())
		Expect(k8sClient.Create(ctx, &corev1.Secret{
			ObjectMeta: metav1.ObjectMeta{Name: credentialsName, Namespace: namespace},
			Immutable:  &immutable,
			Data: map[string][]byte{
				accessKeyIDKey: []byte("bad key"),
				secretKeyKey:   []byte("0123456789abcdef"),
			},
		})).To(Succeed())
		reconcileNow()
		ready = meta.FindStatusCondition(store().Status.Conditions,
			buildkitecomv1alpha1.CacheStoreConditionReady)
		Expect(ready.Reason).To(Equal("CredentialsSecretInvalid"))
		Expect(ready.Message).To(ContainSubstring("access-key ID"))
	})

	Context("with valid Secrets", func() {
		BeforeEach(func() {
			createSecrets()
			createStore()
		})

		It("creates a secure persistent Garage service and lifecycle Job", func() {
			reconcileNow()

			By("creating Garage configuration with a stable RPC identity")
			configMap := &corev1.ConfigMap{}
			Expect(k8sClient.Get(ctx, storeKey, configMap)).To(Succeed())
			Expect(configMap.Data["garage.toml"]).To(ContainSubstring("db_engine = \"sqlite\""))
			Expect(configMap.Data["garage.toml"]).To(ContainSubstring(
				"rpc_public_addr = \"build-cache-0.build-cache-rpc." + namespace + ".svc.cluster.local:3901\""))

			By("exposing only RPC through the headless Service and S3 through the client Service")
			rpcService := &corev1.Service{}
			Expect(k8sClient.Get(ctx, types.NamespacedName{
				Name: garageRPCServiceName(store()), Namespace: namespace,
			}, rpcService)).To(Succeed())
			Expect(rpcService.Spec.ClusterIP).To(Equal(corev1.ClusterIPNone))
			Expect(rpcService.Spec.PublishNotReadyAddresses).To(BeTrue())
			Expect(rpcService.Spec.Ports).To(HaveLen(1))
			Expect(rpcService.Spec.Ports[0].Port).To(BeEquivalentTo(garageRPCPort))

			s3Service := &corev1.Service{}
			Expect(k8sClient.Get(ctx, storeKey, s3Service)).To(Succeed())
			Expect(s3Service.Spec.ClusterIP).NotTo(BeEmpty())
			Expect(s3Service.Spec.Ports).To(HaveLen(1))
			Expect(s3Service.Spec.Ports[0].Port).To(BeEquivalentTo(garageS3Port))

			By("running Garage securely with retained persistent storage")
			sts := statefulSet()
			Expect(sts.Spec.Replicas).To(HaveValue(BeEquivalentTo(1)))
			Expect(sts.Spec.ServiceName).To(Equal(garageRPCServiceName(store())))
			Expect(sts.Spec.PersistentVolumeClaimRetentionPolicy.WhenDeleted).To(Equal(
				appsv1.RetainPersistentVolumeClaimRetentionPolicyType))
			Expect(sts.Spec.PersistentVolumeClaimRetentionPolicy.WhenScaled).To(Equal(
				appsv1.RetainPersistentVolumeClaimRetentionPolicyType))
			Expect(sts.Spec.VolumeClaimTemplates).To(HaveLen(1))
			Expect(sts.Spec.VolumeClaimTemplates[0].Spec.AccessModes).To(Equal(
				[]corev1.PersistentVolumeAccessMode{corev1.ReadWriteOnce}))
			Expect(sts.Spec.VolumeClaimTemplates[0].Spec.Resources.Requests.Storage().String()).To(Equal("2Gi"))
			Expect(sts.Spec.Template.Spec.AutomountServiceAccountToken).To(HaveValue(BeFalse()))
			Expect(sts.Spec.Template.Spec.SecurityContext.RunAsUser).To(HaveValue(BeEquivalentTo(1000)))
			Expect(sts.Spec.Template.Spec.SecurityContext.FSGroup).To(HaveValue(BeEquivalentTo(1000)))
			Expect(sts.Spec.Template.Spec.SecurityContext.SeccompProfile.Type).To(Equal(
				corev1.SeccompProfileTypeRuntimeDefault))

			Expect(sts.Spec.Template.Spec.Containers).To(HaveLen(1))
			garage := sts.Spec.Template.Spec.Containers[0]
			Expect(garage.Image).To(Equal(defaultGarageImage))
			Expect(garage.Command).To(Equal([]string{"/garage"}))
			Expect(garage.Args).To(Equal([]string{"server", "--single-node", "--default-bucket"}))
			Expect(garage.SecurityContext.ReadOnlyRootFilesystem).To(HaveValue(BeTrue()))
			Expect(garage.SecurityContext.AllowPrivilegeEscalation).To(HaveValue(BeFalse()))
			Expect(garage.SecurityContext.Capabilities.Drop).To(ContainElement(corev1.Capability("ALL")))
			Expect(garage.ReadinessProbe.HTTPGet.Path).To(Equal("/health"))
			Expect(garage.LivenessProbe.HTTPGet.Port.String()).To(Equal("admin"))
			Expect(garage.Env).To(ContainElement(corev1.EnvVar{
				Name:  "GARAGE_DEFAULT_BUCKET",
				Value: defaultCacheBucket,
			}))

			By("applying and verifying lifecycle configuration with the pinned AWS CLI")
			jobs := lifecycleJobs()
			Expect(jobs).To(HaveLen(1))
			job := jobs[0]
			Expect(job.Spec.Template.Spec.AutomountServiceAccountToken).To(HaveValue(BeFalse()))
			Expect(job.Spec.Template.Spec.Containers).To(HaveLen(1))
			lifecycle := job.Spec.Template.Spec.Containers[0]
			Expect(lifecycle.Image).To(Equal(defaultLifecycleImage))
			Expect(lifecycle.Args).To(HaveLen(1))
			Expect(lifecycle.Args[0]).To(ContainSubstring(`"Expiration":{"Days":2}`))
			Expect(lifecycle.Args[0]).To(ContainSubstring("get-bucket-lifecycle-configuration"))
			Expect(lifecycle.Args[0]).To(ContainSubstring(
				"--query 'length(Rules[?ID==`\"buildkite-cache-retention\"`"))
			Expect(lifecycle.SecurityContext.ReadOnlyRootFilesystem).To(HaveValue(BeTrue()))

			By("reporting the StatefulSet as pending until its controller makes it ready")
			ready := meta.FindStatusCondition(store().Status.Conditions,
				buildkitecomv1alpha1.CacheStoreConditionReady)
			Expect(ready.Status).To(Equal(metav1.ConditionUnknown))
			Expect(ready.Reason).To(Equal("StatefulSetPending"))
		})

		It("does not rewrite resources when desired state is unchanged", func() {
			reconcileNow()
			configMap := &corev1.ConfigMap{}
			Expect(k8sClient.Get(ctx, storeKey, configMap)).To(Succeed())
			rpcService := &corev1.Service{}
			rpcServiceKey := types.NamespacedName{Name: garageRPCServiceName(store()), Namespace: namespace}
			Expect(k8sClient.Get(ctx, rpcServiceKey, rpcService)).To(Succeed())
			s3Service := &corev1.Service{}
			Expect(k8sClient.Get(ctx, storeKey, s3Service)).To(Succeed())
			beforeConfig := configMap.ResourceVersion
			beforeRPCService := rpcService.ResourceVersion
			beforeS3Service := s3Service.ResourceVersion
			beforeStatefulSet := statefulSet().ResourceVersion
			beforeJob := lifecycleJobs()[0].ResourceVersion

			reconcileNow()
			reconcileNow()

			Expect(k8sClient.Get(ctx, storeKey, configMap)).To(Succeed())
			Expect(k8sClient.Get(ctx, rpcServiceKey, rpcService)).To(Succeed())
			Expect(k8sClient.Get(ctx, storeKey, s3Service)).To(Succeed())
			Expect(configMap.ResourceVersion).To(Equal(beforeConfig))
			Expect(rpcService.ResourceVersion).To(Equal(beforeRPCService))
			Expect(s3Service.ResourceVersion).To(Equal(beforeS3Service))
			Expect(statefulSet().ResourceVersion).To(Equal(beforeStatefulSet))
			Expect(lifecycleJobs()[0].ResourceVersion).To(Equal(beforeJob))
		})

		It("corrects mutable resource drift", func() {
			reconcileNow()
			configMap := &corev1.ConfigMap{}
			Expect(k8sClient.Get(ctx, storeKey, configMap)).To(Succeed())
			configMap.Data["garage.toml"] = "wrong"
			Expect(k8sClient.Update(ctx, configMap)).To(Succeed())

			sts := statefulSet()
			sts.Spec.Template.Spec.Containers[0].Image = "example.invalid/garage:wrong"
			Expect(k8sClient.Update(ctx, sts)).To(Succeed())

			reconcileNow()
			Expect(k8sClient.Get(ctx, storeKey, configMap)).To(Succeed())
			Expect(configMap.Data["garage.toml"]).To(ContainSubstring("replication_factor = 1"))
			Expect(statefulSet().Spec.Template.Spec.Containers[0].Image).To(Equal(defaultGarageImage))
		})

		It("becomes Ready only after Garage and lifecycle configuration succeed", func() {
			reconcileNow()
			sts := statefulSet()
			sts.Status.ObservedGeneration = sts.Generation
			sts.Status.Replicas = 1
			sts.Status.ReadyReplicas = 1
			Expect(k8sClient.Status().Update(ctx, sts)).To(Succeed())

			job := lifecycleJobs()[0]
			now := metav1.Now()
			job.Status.Succeeded = 1
			job.Status.StartTime = &now
			job.Status.CompletionTime = &now
			job.Status.Conditions = []batchv1.JobCondition{
				{Type: batchv1.JobSuccessCriteriaMet, Status: corev1.ConditionTrue, LastTransitionTime: now},
				{Type: batchv1.JobComplete, Status: corev1.ConditionTrue, LastTransitionTime: now},
			}
			Expect(k8sClient.Status().Update(ctx, &job)).To(Succeed())

			reconcileNow()
			current := store()
			ready := meta.FindStatusCondition(current.Status.Conditions,
				buildkitecomv1alpha1.CacheStoreConditionReady)
			Expect(ready.Status).To(Equal(metav1.ConditionTrue))
			Expect(ready.Reason).To(Equal("CacheStoreAvailable"))
			Expect(current.Status.ObservedGeneration).To(Equal(current.Generation))
		})

		It("deletes the old lifecycle Job before creating its replacement", func() {
			reconcileNow()
			oldName := lifecycleJobs()[0].Name
			current := store()
			current.Spec.RetentionDays = 5
			Expect(k8sClient.Update(ctx, current)).To(Succeed())

			reconcileNow()
			jobs := lifecycleJobs()
			Expect(jobs).To(HaveLen(1))
			Expect(jobs[0].Name).To(Equal(oldName))
			Expect(jobs[0].DeletionTimestamp).NotTo(BeNil())

			// envtest does not run the garbage collector, so finish the
			// foreground deletion it would perform after stopping Job Pods.
			jobs[0].Finalizers = nil
			Expect(k8sClient.Update(ctx, &jobs[0])).To(Succeed())
			Eventually(func(g Gomega) {
				g.Expect(lifecycleJobs()).To(BeEmpty())
			}).Should(Succeed())

			reconcileNow()
			jobs = lifecycleJobs()
			Expect(jobs).To(HaveLen(1))
			Expect(jobs[0].Name).NotTo(Equal(oldName))
			Expect(jobs[0].Spec.Template.Spec.Containers[0].Args[0]).To(ContainSubstring(
				`"Expiration":{"Days":5}`))
		})

		It("preserves provisioned resources when a referenced Secret is deleted", func() {
			reconcileNow()
			before := statefulSet().ResourceVersion
			Expect(k8sClient.Delete(ctx, &corev1.Secret{
				ObjectMeta: metav1.ObjectMeta{Name: rpcSecretName, Namespace: namespace},
			})).To(Succeed())

			reconcileNow()
			Expect(statefulSet().ResourceVersion).To(Equal(before))
			ready := meta.FindStatusCondition(store().Status.Conditions,
				buildkitecomv1alpha1.CacheStoreConditionReady)
			Expect(ready.Status).To(Equal(metav1.ConditionFalse))
			Expect(ready.Reason).To(Equal("RPCSecretNotFound"))
		})
	})

	It("defaults mutable settings and rejects immutable or invalid API updates", func() {
		created := createStore()
		Expect(created.Spec.Image).To(Equal(defaultGarageImage))
		Expect(created.Spec.Bucket).To(Equal(defaultCacheBucket))
		Expect(created.Spec.RetentionDays).To(BeEquivalentTo(defaultRetentionDays))
		Expect(created.Spec.LifecycleImage).To(Equal(defaultLifecycleImage))

		By("rejecting a bucket change")
		created.Spec.Bucket = "another-bucket"
		err := k8sClient.Update(ctx, created)
		Expect(err).To(HaveOccurred())
		Expect(err.Error()).To(ContainSubstring("bucket is immutable"))

		By("rejecting a storage change")
		created = store()
		created.Spec.Storage.Size = resource.MustParse("3Gi")
		err = k8sClient.Update(ctx, created)
		Expect(err).To(HaveOccurred())
		Expect(err.Error()).To(ContainSubstring("storage is immutable"))

		By("rejecting invalid S3 bucket names")
		invalid := newStore("invalid-bucket")
		invalid.Spec.Bucket = "192.168.1.1"
		err = k8sClient.Create(ctx, invalid)
		Expect(err).To(HaveOccurred())
		Expect(err.Error()).To(ContainSubstring("IP address"))
	})
})
