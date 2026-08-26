// Copyright (c) 2026 Buildkite Pty Ltd
// SPDX-License-Identifier: MIT

//go:build e2e
// +build e2e

package e2e

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/buildkite/buildkite-operator/test/utils"
)

// namespace where the project is deployed in
const namespace = "buildkite-operator-system"

// poolNamespace is where the e2e RunnerPool lives, kept separate from the
// manager's namespace so the agent pods are not subject to its restricted pod
// security policy.
const poolNamespace = "buildkite-operator-e2e"

// runnerPoolManifest is the RunnerPool fixture, applied relative to the project
// root that utils.Run executes in.
const runnerPoolManifest = "test/e2e/testdata/runnerpool.yaml"

// cacheClientManifest exercises Garage's S3 API after the lifecycle rule is ready.
const cacheClientManifest = "test/e2e/testdata/cache-client.yaml"

// serviceAccountName created for the project
const serviceAccountName = "buildkite-operator-controller-manager"

// metricsServiceName is the name of the metrics service of the project
const metricsServiceName = "buildkite-operator-controller-manager-metrics-service"

// metricsRoleBindingName is the name of the RBAC that will be created to allow get the metrics data
const metricsRoleBindingName = "buildkite-operator-metrics-binding"

var _ = Describe("Manager", Ordered, func() {
	var controllerPodName string

	// Before running the tests, set up the environment by creating the namespace,
	// enforce the restricted security policy to the namespace, installing CRDs,
	// and deploying the controller.
	BeforeAll(func() {
		By("creating manager namespace")
		cmd := exec.Command("kubectl", "create", "ns", namespace)
		_, err := utils.Run(cmd)
		Expect(err).NotTo(HaveOccurred(), "Failed to create namespace")

		By("labeling the namespace to enforce the restricted security policy")
		cmd = exec.Command("kubectl", "label", "--overwrite", "ns", namespace,
			"pod-security.kubernetes.io/enforce=restricted")
		_, err = utils.Run(cmd)
		Expect(err).NotTo(HaveOccurred(), "Failed to label namespace with restricted policy")

		By("installing CRDs")
		cmd = exec.Command("make", "install")
		_, err = utils.Run(cmd)
		Expect(err).NotTo(HaveOccurred(), "Failed to install CRDs")

		By("deploying the controller-manager")
		cmd = exec.Command("make", "deploy", fmt.Sprintf("IMG=%s", managerImage))
		_, err = utils.Run(cmd)
		Expect(err).NotTo(HaveOccurred(), "Failed to deploy the controller-manager")
	})

	// After all tests have been executed, clean up by undeploying the controller, uninstalling CRDs,
	// and deleting the namespace.
	AfterAll(func() {
		By("cleaning up the curl pod for metrics")
		cmd := exec.Command("kubectl", "delete", "pod", "curl-metrics", "-n", namespace)
		_, _ = utils.Run(cmd)

		By("undeploying the controller-manager")
		cmd = exec.Command("make", "undeploy")
		_, _ = utils.Run(cmd)

		By("uninstalling CRDs")
		cmd = exec.Command("make", "uninstall")
		_, _ = utils.Run(cmd)

		By("removing manager namespace")
		cmd = exec.Command("kubectl", "delete", "ns", namespace)
		_, _ = utils.Run(cmd)
	})

	// After each test, check for failures and collect logs, events,
	// and pod descriptions for debugging.
	AfterEach(func() {
		specReport := CurrentSpecReport()
		if specReport.Failed() {
			By("Fetching controller manager pod logs")
			cmd := exec.Command("kubectl", "logs", controllerPodName, "-n", namespace)
			controllerLogs, err := utils.Run(cmd)
			if err == nil {
				_, _ = fmt.Fprintf(GinkgoWriter, "Controller logs:\n %s", controllerLogs)
			} else {
				_, _ = fmt.Fprintf(GinkgoWriter, "Failed to get Controller logs: %s", err)
			}

			By("Fetching Kubernetes events")
			cmd = exec.Command("kubectl", "get", "events", "-n", namespace, "--sort-by=.lastTimestamp")
			eventsOutput, err := utils.Run(cmd)
			if err == nil {
				_, _ = fmt.Fprintf(GinkgoWriter, "Kubernetes events:\n%s", eventsOutput)
			} else {
				_, _ = fmt.Fprintf(GinkgoWriter, "Failed to get Kubernetes events: %s", err)
			}

			By("Fetching curl-metrics logs")
			cmd = exec.Command("kubectl", "logs", "curl-metrics", "-n", namespace)
			metricsOutput, err := utils.Run(cmd)
			if err == nil {
				_, _ = fmt.Fprintf(GinkgoWriter, "Metrics logs:\n %s", metricsOutput)
			} else {
				_, _ = fmt.Fprintf(GinkgoWriter, "Failed to get curl-metrics logs: %s", err)
			}

			By("Fetching controller manager pod description")
			cmd = exec.Command("kubectl", "describe", "pod", controllerPodName, "-n", namespace)
			podDescription, err := utils.Run(cmd)
			if err == nil {
				fmt.Println("Pod description:\n", podDescription)
			} else {
				fmt.Println("Failed to describe controller pod")
			}
		}
	})

	SetDefaultEventuallyTimeout(2 * time.Minute)
	SetDefaultEventuallyPollingInterval(time.Second)

	Context("Manager", func() {
		It("should run successfully", func() {
			By("validating that the controller-manager pod is running as expected")
			verifyControllerUp := func(g Gomega) {
				By("getting the name of the controller-manager pod")
				cmd := exec.Command("kubectl", "get",
					"pods", "-l", "control-plane=controller-manager",
					"-o", "go-template={{ range .items }}"+
						"{{ if not .metadata.deletionTimestamp }}"+
						"{{ .metadata.name }}"+
						"{{ \"\\n\" }}{{ end }}{{ end }}",
					"-n", namespace,
				)

				podOutput, err := utils.Run(cmd)
				g.Expect(err).NotTo(HaveOccurred(), "Failed to retrieve controller-manager pod information")
				podNames := utils.GetNonEmptyLines(podOutput)
				g.Expect(podNames).To(HaveLen(1), "expected 1 controller pod running")
				controllerPodName = podNames[0]
				g.Expect(controllerPodName).To(ContainSubstring("controller-manager"))

				By("validating the pod's status")
				cmd = exec.Command("kubectl", "get",
					"pods", controllerPodName, "-o", "jsonpath={.status.phase}",
					"-n", namespace,
				)
				output, err := utils.Run(cmd)
				g.Expect(err).NotTo(HaveOccurred())
				g.Expect(output).To(Equal("Running"), "Incorrect controller-manager pod status")
			}
			Eventually(verifyControllerUp).Should(Succeed())
		})

		It("should ensure the metrics endpoint is serving metrics", func() {
			By("creating a ClusterRoleBinding for the service account to allow access to metrics")
			cmd := exec.Command("kubectl", "create", "clusterrolebinding", metricsRoleBindingName,
				"--clusterrole=buildkite-operator-metrics-reader",
				fmt.Sprintf("--serviceaccount=%s:%s", namespace, serviceAccountName),
			)
			_, err := utils.Run(cmd)
			Expect(err).NotTo(HaveOccurred(), "Failed to create ClusterRoleBinding")

			By("validating that the metrics service is available")
			cmd = exec.Command("kubectl", "get", "service", metricsServiceName, "-n", namespace)
			_, err = utils.Run(cmd)
			Expect(err).NotTo(HaveOccurred(), "Metrics service should exist")

			By("getting the service account token")
			token, err := serviceAccountToken()
			Expect(err).NotTo(HaveOccurred())
			Expect(token).NotTo(BeEmpty())

			By("ensuring the controller pod is ready")
			verifyControllerPodReady := func(g Gomega) {
				cmd := exec.Command("kubectl", "get", "pod", controllerPodName, "-n", namespace,
					"-o", "jsonpath={.status.conditions[?(@.type=='Ready')].status}")
				output, err := utils.Run(cmd)
				g.Expect(err).NotTo(HaveOccurred())
				g.Expect(output).To(Equal("True"), "Controller pod not ready")
			}
			Eventually(verifyControllerPodReady, 3*time.Minute, time.Second).Should(Succeed())

			By("verifying that the controller manager is serving the metrics server")
			verifyMetricsServerStarted := func(g Gomega) {
				cmd := exec.Command("kubectl", "logs", controllerPodName, "-n", namespace)
				output, err := utils.Run(cmd)
				g.Expect(err).NotTo(HaveOccurred())
				g.Expect(output).To(ContainSubstring("Serving metrics server"),
					"Metrics server not yet started")
			}
			Eventually(verifyMetricsServerStarted, 3*time.Minute, time.Second).Should(Succeed())

			// +kubebuilder:scaffold:e2e-metrics-webhooks-readiness

			By("creating the curl-metrics pod to access the metrics endpoint")
			cmd = exec.Command("kubectl", "run", "curl-metrics", "--restart=Never",
				"--namespace", namespace,
				"--image=curlimages/curl:latest",
				"--overrides",
				fmt.Sprintf(`{
					"spec": {
						"containers": [{
							"name": "curl",
							"image": "curlimages/curl:latest",
							"command": ["/bin/sh", "-c"],
							"args": [
								"for i in $(seq 1 30); do curl -v -k -H 'Authorization: Bearer %s' https://%s.%s.svc.cluster.local:8443/metrics && exit 0 || sleep 2; done; exit 1"
							],
							"securityContext": {
								"readOnlyRootFilesystem": true,
								"allowPrivilegeEscalation": false,
								"capabilities": {
									"drop": ["ALL"]
								},
								"runAsNonRoot": true,
								"runAsUser": 1000,
								"seccompProfile": {
									"type": "RuntimeDefault"
								}
							}
						}],
						"serviceAccountName": "%s"
					}
				}`, token, metricsServiceName, namespace, serviceAccountName))
			_, err = utils.Run(cmd)
			Expect(err).NotTo(HaveOccurred(), "Failed to create curl-metrics pod")

			By("waiting for the curl-metrics pod to complete.")
			verifyCurlUp := func(g Gomega) {
				cmd := exec.Command("kubectl", "get", "pods", "curl-metrics",
					"-o", "jsonpath={.status.phase}",
					"-n", namespace)
				output, err := utils.Run(cmd)
				g.Expect(err).NotTo(HaveOccurred())
				g.Expect(output).To(Equal("Succeeded"), "curl pod in wrong status")
			}
			Eventually(verifyCurlUp, 5*time.Minute).Should(Succeed())

			By("getting the metrics by checking curl-metrics logs")
			verifyMetricsAvailable := func(g Gomega) {
				metricsOutput, err := getMetricsOutput()
				g.Expect(err).NotTo(HaveOccurred(), "Failed to retrieve logs from curl pod")
				g.Expect(metricsOutput).NotTo(BeEmpty())
				g.Expect(metricsOutput).To(ContainSubstring("< HTTP/1.1 200 OK"))
			}
			Eventually(verifyMetricsAvailable, 2*time.Minute).Should(Succeed())
		})

		// +kubebuilder:scaffold:e2e-webhooks-checks
	})

	Context("CacheStore and RunnerPool", func() {
		It("serves an agent-managed cache to directly owned agent Pods", func() {
			By("applying a CacheStore, RunnerPool, and their immutable Secrets")
			cmd := exec.Command("kubectl", "apply", "-f", runnerPoolManifest)
			_, err := utils.Run(cmd)
			Expect(err).NotTo(HaveOccurred(), "Failed to apply the RunnerPool")

			DeferCleanup(func() {
				By("deleting the RunnerPool namespace")
				cmd := exec.Command("kubectl", "delete", "-f", runnerPoolManifest, "--ignore-not-found")
				_, _ = utils.Run(cmd)
			})

			By("waiting for Garage and its lifecycle rule to become ready")
			cmd = exec.Command("kubectl", "wait", "--for=create", "statefulset/e2e-cache",
				"-n", poolNamespace, "--timeout=2m")
			_, err = utils.Run(cmd)
			Expect(err).NotTo(HaveOccurred(), "Garage StatefulSet was not created")
			cmd = exec.Command("kubectl", "rollout", "status", "statefulset/e2e-cache",
				"-n", poolNamespace, "--timeout=5m")
			_, err = utils.Run(cmd)
			Expect(err).NotTo(HaveOccurred(), "Garage StatefulSet never became ready")
			cmd = exec.Command("kubectl", "wait", "cachestore/e2e-cache",
				"--for=condition=Ready", "-n", poolNamespace, "--timeout=5m")
			_, err = utils.Run(cmd)
			Expect(err).NotTo(HaveOccurred(), "CacheStore never reported Ready")

			By("retaining the PVC on CacheStore deletion and scale-down")
			cmd = exec.Command("kubectl", "get", "statefulset/e2e-cache", "-n", poolNamespace,
				"-o", "jsonpath={.spec.persistentVolumeClaimRetentionPolicy.whenDeleted}/{.spec.persistentVolumeClaimRetentionPolicy.whenScaled}")
			output, err := utils.Run(cmd)
			Expect(err).NotTo(HaveOccurred())
			Expect(output).To(Equal("Retain/Retain"))

			By("exposing only RPC through the headless Service and S3 through the client Service")
			cmd = exec.Command("kubectl", "get", "service/e2e-cache-rpc", "-n", poolNamespace,
				"-o", "jsonpath={.spec.clusterIP}/{.spec.ports[0].port}")
			output, err = utils.Run(cmd)
			Expect(err).NotTo(HaveOccurred())
			Expect(output).To(Equal("None/3901"))
			cmd = exec.Command("kubectl", "get", "service/e2e-cache", "-n", poolNamespace,
				"-o", "jsonpath={.spec.ports[*].port}")
			output, err = utils.Run(cmd)
			Expect(err).NotTo(HaveOccurred())
			Expect(output).To(Equal("3900"))

			By("waiting for the operator to create an agent Pod")
			var agentPodName string
			verifyAgentPodRunning := func(g Gomega) {
				cmd := exec.Command("kubectl", "get", "pods",
					"-l", "buildkite.com/runner-pool=e2e-pool",
					"-o", "jsonpath={.items[0].metadata.name}", "-n", poolNamespace)
				output, err := utils.Run(cmd)
				g.Expect(err).NotTo(HaveOccurred())
				g.Expect(output).NotTo(BeEmpty())
				agentPodName = output

				cmd = exec.Command("kubectl", "get", "pod/"+agentPodName,
					"-o", "jsonpath={.status.phase}", "-n", poolNamespace)
				output, err = utils.Run(cmd)
				g.Expect(err).NotTo(HaveOccurred())
				g.Expect(output).To(Equal("Running"))
			}
			Eventually(verifyAgentPodRunning, 3*time.Minute).Should(Succeed())

			By("reporting the agent Pod in RunnerPool status")
			verifyTotalRunners := func(g Gomega) {
				cmd := exec.Command("kubectl", "get", "runnerpool/e2e-pool",
					"-o", "jsonpath={.status.totalRunners}", "-n", poolNamespace)
				output, err := utils.Run(cmd)
				g.Expect(err).NotTo(HaveOccurred())
				g.Expect(output).To(Equal("1"), "RunnerPool did not report its agent Pod")
			}
			Eventually(verifyTotalRunners, time.Minute).Should(Succeed())

			By("setting a controller owner reference on the agent Pod")
			cmd = exec.Command("kubectl", "get", "pod/"+agentPodName, "-n", poolNamespace,
				"-o", "jsonpath={.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}")
			output, err = utils.Run(cmd)
			Expect(err).NotTo(HaveOccurred())
			Expect(output).To(Equal("RunnerPool/e2e-pool"))

			By("passing the queue through to the agents as a tag")
			cmd = exec.Command("kubectl", "get", "pod/"+agentPodName, "-n", poolNamespace,
				"-o", "jsonpath={.spec.containers[0].env[?(@.name=='BUILDKITE_AGENT_TAGS')].value}")
			output, err = utils.Run(cmd)
			Expect(err).NotTo(HaveOccurred())
			Expect(output).To(Equal("queue=e2e"))

			By("reporting CacheStore readiness on the RunnerPool")
			cmd = exec.Command("kubectl", "wait", "runnerpool/e2e-pool",
				"--for=condition=CacheStoreReady", "-n", poolNamespace, "--timeout=2m")
			_, err = utils.Run(cmd)
			Expect(err).NotTo(HaveOccurred(), "RunnerPool never reported CacheStoreReady")

			By("injecting the encoded S3 URL and credential references")
			cmd = exec.Command("kubectl", "get", "pod/"+agentPodName, "-n", poolNamespace,
				"-o", "jsonpath={.spec.containers[0].env[?(@.name=='BUILDKITE_AGENT_CACHE_STORE_URL')].value}")
			output, err = utils.Run(cmd)
			Expect(err).NotTo(HaveOccurred())
			cacheURL, err := url.Parse(output)
			Expect(err).NotTo(HaveOccurred())
			Expect(cacheURL.Scheme).To(Equal("s3"))
			Expect(cacheURL.Host).To(Equal("buildkite-cache"))
			Expect(cacheURL.Query().Get("region")).To(Equal("garage"))
			Expect(cacheURL.Query().Get("endpoint")).To(Equal(
				"http://e2e-cache.buildkite-operator-e2e.svc:3900"))
			Expect(cacheURL.Query().Get("use_path_style")).To(Equal("true"))
			cmd = exec.Command("kubectl", "get", "pod/"+agentPodName, "-n", poolNamespace,
				"-o", "jsonpath={.spec.containers[0].env[?(@.name=='AWS_ACCESS_KEY_ID')].valueFrom.secretKeyRef.name}/{.spec.containers[0].env[?(@.name=='AWS_ACCESS_KEY_ID')].valueFrom.secretKeyRef.key}")
			output, err = utils.Run(cmd)
			Expect(err).NotTo(HaveOccurred())
			Expect(output).To(Equal("e2e-cache-credentials/access-key-id"))

			By("exercising put, head, get, self-copy, multipart upload, and lifecycle APIs")
			cmd = exec.Command("kubectl", "apply", "-f", cacheClientManifest)
			_, err = utils.Run(cmd)
			Expect(err).NotTo(HaveOccurred(), "Failed to apply the S3 client Job")
			DeferCleanup(func() {
				cmd := exec.Command("kubectl", "delete", "-f", cacheClientManifest, "--ignore-not-found")
				_, _ = utils.Run(cmd)
			})
			cmd = exec.Command("kubectl", "wait", "job/cache-store-client", "--for=condition=Complete",
				"-n", poolNamespace, "--timeout=5m")
			_, err = utils.Run(cmd)
			Expect(err).NotTo(HaveOccurred(), "S3 client Job did not complete")
			cmd = exec.Command("kubectl", "logs", "job/cache-store-client", "-n", poolNamespace)
			output, err = utils.Run(cmd)
			Expect(err).NotTo(HaveOccurred())
			Expect(output).To(ContainSubstring("CACHE_STORE_E2E_OK"))

			By("leaving the Garage PVC behind when the CacheStore is deleted")
			cmd = exec.Command("kubectl", "delete", "cachestore/e2e-cache", "-n", poolNamespace)
			_, err = utils.Run(cmd)
			Expect(err).NotTo(HaveOccurred())
			Eventually(func(g Gomega) {
				cmd := exec.Command("kubectl", "get", "statefulset/e2e-cache", "-n", poolNamespace)
				_, err := utils.Run(cmd)
				g.Expect(err).To(HaveOccurred())
			}).Should(Succeed())
			cmd = exec.Command("kubectl", "get", "pvc/data-e2e-cache-0", "-n", poolNamespace)
			_, err = utils.Run(cmd)
			Expect(err).NotTo(HaveOccurred(), "Garage PVC was deleted with its CacheStore")

			By("garbage collecting agent Pods when the pool is deleted")
			cmd = exec.Command("kubectl", "delete", "runnerpool/e2e-pool", "-n", poolNamespace)
			_, err = utils.Run(cmd)
			Expect(err).NotTo(HaveOccurred(), "Failed to delete the RunnerPool")

			verifyAgentPodsGone := func(g Gomega) {
				// -o name prints nothing when there are no matches; --no-headers
				// still prints "No resources found in <namespace> namespace."
				cmd := exec.Command("kubectl", "get", "pods",
					"-l", "buildkite.com/runner-pool=e2e-pool", "-o", "name", "-n", poolNamespace)
				output, err := utils.Run(cmd)
				g.Expect(err).NotTo(HaveOccurred())
				g.Expect(output).To(BeEmpty(), "Agent Pods outlived their RunnerPool")
			}
			Eventually(verifyAgentPodsGone, 2*time.Minute).Should(Succeed())
		})
	})
})

// serviceAccountToken returns a token for the specified service account in the given namespace.
// It uses the Kubernetes TokenRequest API to generate a token by directly sending a request
// and parsing the resulting token from the API response.
func serviceAccountToken() (string, error) {
	const tokenRequestRawString = `{
		"apiVersion": "authentication.k8s.io/v1",
		"kind": "TokenRequest"
	}`

	By("creating temporary file to store the token request")
	secretName := fmt.Sprintf("%s-token-request", serviceAccountName)
	tokenRequestFile := filepath.Join("/tmp", secretName)
	err := os.WriteFile(tokenRequestFile, []byte(tokenRequestRawString), os.FileMode(0o644))
	if err != nil {
		return "", err
	}

	var out string
	verifyTokenCreation := func(g Gomega) {
		By("executing kubectl command to create the token")
		cmd := exec.Command("kubectl", "create", "--raw", fmt.Sprintf(
			"/api/v1/namespaces/%s/serviceaccounts/%s/token",
			namespace,
			serviceAccountName,
		), "-f", tokenRequestFile)

		output, err := cmd.CombinedOutput()
		g.Expect(err).NotTo(HaveOccurred())

		By("parsing the JSON output to extract the token")
		var token tokenRequest
		err = json.Unmarshal(output, &token)
		g.Expect(err).NotTo(HaveOccurred())

		out = token.Status.Token
	}
	Eventually(verifyTokenCreation).Should(Succeed())

	return out, err
}

// getMetricsOutput retrieves and returns the logs from the curl pod used to access the metrics endpoint.
func getMetricsOutput() (string, error) {
	By("getting the curl-metrics logs")
	cmd := exec.Command("kubectl", "logs", "curl-metrics", "-n", namespace)
	return utils.Run(cmd)
}

// tokenRequest is a simplified representation of the Kubernetes TokenRequest API response,
// containing only the token field that we need to extract.
type tokenRequest struct {
	Status struct {
		Token string `json:"token"`
	} `json:"status"`
}
