// Copyright (c) 2026 Buildkite Pty Ltd
// SPDX-License-Identifier: MIT

//go:build e2e
// +build e2e

package e2e

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
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

	Context("RunnerPool", func() {
		It("runs and supervises an autoscaled agent inside a private Docker daemon", func() {
			By("applying a RunnerPool and the agent token secret it references")
			cmd := exec.Command("kubectl", "apply", "-f", runnerPoolManifest)
			_, err := utils.Run(cmd)
			Expect(err).NotTo(HaveOccurred(), "Failed to apply the RunnerPool")

			DeferCleanup(func() {
				By("deleting the RunnerPool namespace")
				cmd := exec.Command("kubectl", "delete", "-f", runnerPoolManifest, "--ignore-not-found")
				_, _ = utils.Run(cmd)
			})

			By("waiting for the in-cluster HTTP fixture to become available")
			cmd = exec.Command("kubectl", "wait", "deployment/e2e-http",
				"--for=condition=Available", "-n", poolNamespace, "--timeout=3m")
			_, err = utils.Run(cmd)
			Expect(err).NotTo(HaveOccurred(), "HTTP fixture never became available")

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

			By("reporting the runner Pod in RunnerPool status")
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
			output, err := utils.Run(cmd)
			Expect(err).NotTo(HaveOccurred())
			Expect(output).To(Equal("RunnerPool/e2e-pool"))

			docker := func(args ...string) (string, error) {
				GinkgoHelper()
				kubectlArgs := []string{"exec", agentPodName, "-n", poolNamespace, "-c", "supervisor", "--", "docker"}
				cmd := exec.Command("kubectl", append(kubectlArgs, args...)...)
				output, err := utils.Run(cmd)
				return strings.TrimSpace(output), err
			}

			By("verifying dockerd and the inner agent are running")
			output, err = docker("info", "--format", "{{.ServerVersion}}")
			Expect(err).NotTo(HaveOccurred())
			Expect(output).NotTo(BeEmpty())
			var agentID string
			Eventually(func(g Gomega) {
				var err error
				agentID, err = docker("inspect", "--format", "{{.Id}}", "buildkite-agent")
				g.Expect(err).NotTo(HaveOccurred())
				g.Expect(agentID).NotTo(BeEmpty())
			}, 2*time.Minute, time.Second).Should(Succeed())
			healthPort, err := docker("inspect", "--format",
				"{{(index (index .HostConfig.PortBindings \"8080/tcp\") 0).HostPort}}", "buildkite-agent")
			Expect(err).NotTo(HaveOccurred())
			Expect(healthPort).To(Equal("8080"))
			agentEnv, err := docker("inspect", "--format", "{{range .Config.Env}}{{println .}}{{end}}", "buildkite-agent")
			Expect(err).NotTo(HaveOccurred())
			Expect(agentEnv).To(ContainSubstring("BUILDKITE_AGENT_TAGS=queue=e2e"))
			Expect(agentEnv).To(ContainSubstring("BUILDKITE_AGENT_HEALTH_CHECK_ADDR=0.0.0.0:8080"))

			By("launching a Docker client that launches a nested job container")
			output, err = docker("run", "--rm",
				"--volume", "/var/run/docker.sock:/var/run/docker.sock",
				"docker:29.7.2-cli",
				"docker", "run", "--rm", "busybox:1.37", "echo", "nested-ok")
			Expect(err).NotTo(HaveOccurred())
			Expect(output).To(ContainSubstring("nested-ok"))

			By("sharing workspace paths with nested containers")
			_, err = docker("run", "--rm", "--volume", "/workspace:/workspace",
				"busybox:1.37", "sh", "-c", "echo workspace-ok > /workspace/e2e.txt")
			Expect(err).NotTo(HaveOccurred())
			output, err = docker("run", "--rm", "--volume", "/workspace:/workspace",
				"busybox:1.37", "cat", "/workspace/e2e.txt")
			Expect(err).NotTo(HaveOccurred())
			Expect(output).To(Equal("workspace-ok"))

			By("reaching a Kubernetes Service from an inner Docker container")
			output, err = docker("run", "--rm", "busybox:1.37", "wget", "-qO-",
				"http://e2e-http.buildkite-operator-e2e.svc.cluster.local/hostname")
			Expect(err).NotTo(HaveOccurred())
			Expect(output).NotTo(BeEmpty())

			By("replacing the inner agent after it exits")
			_, err = docker("rm", "--force", "buildkite-agent")
			Expect(err).NotTo(HaveOccurred())
			replacementStarted := time.Now()
			var replacementID string
			Eventually(func(g Gomega) {
				var err error
				replacementID, err = docker("inspect", "--format", "{{.Id}}", "buildkite-agent")
				g.Expect(err).NotTo(HaveOccurred())
				g.Expect(replacementID).NotTo(BeEmpty())
				g.Expect(replacementID).NotTo(Equal(agentID))
			}, 2*time.Minute, time.Second).Should(Succeed())
			Expect(time.Since(replacementStarted)).To(BeNumerically(">=", 4*time.Second))

			By("adopting the inner agent when the supervisor restarts")
			cmd = exec.Command("kubectl", "get", "pod", agentPodName, "-n", poolNamespace,
				"-o", "jsonpath={.status.containerStatuses[?(@.name=='supervisor')].restartCount}")
			restartCount, err := utils.Run(cmd)
			Expect(err).NotTo(HaveOccurred())
			cmd = exec.Command("kubectl", "get", "pod", agentPodName, "-n", poolNamespace,
				"-o", "jsonpath={.spec.nodeName}")
			nodeName, err := utils.Run(cmd)
			Expect(err).NotTo(HaveOccurred())
			cmd = exec.Command("kubectl", "get", "pod", agentPodName, "-n", poolNamespace,
				"-o", "jsonpath={.status.containerStatuses[?(@.name=='supervisor')].containerID}")
			supervisorContainerID, err := utils.Run(cmd)
			Expect(err).NotTo(HaveOccurred())
			supervisorContainerID = strings.TrimPrefix(strings.TrimSpace(supervisorContainerID), "containerd://")
			cmd = exec.Command("docker", "exec", strings.TrimSpace(nodeName),
				"ctr", "--namespace", "k8s.io", "tasks", "kill", "--signal", "SIGKILL", supervisorContainerID)
			_, err = utils.Run(cmd)
			Expect(err).NotTo(HaveOccurred(), "Failed to crash the supervisor container")
			Eventually(func(g Gomega) {
				cmd := exec.Command("kubectl", "get", "pod", agentPodName, "-n", poolNamespace,
					"-o", "jsonpath={.status.containerStatuses[?(@.name=='supervisor')].restartCount}")
				output, err := utils.Run(cmd)
				g.Expect(err).NotTo(HaveOccurred())
				g.Expect(output).NotTo(Equal(restartCount))
			}, time.Minute, time.Second).Should(Succeed())
			Eventually(func(g Gomega) {
				output, err := docker("inspect", "--format", "{{.Id}}", "buildkite-agent")
				g.Expect(err).NotTo(HaveOccurred())
				g.Expect(output).To(Equal(replacementID))
			}, time.Minute, time.Second).Should(Succeed())

			By("cleaning child containers and networks while retaining images and workspace")
			_, err = docker("run", "--detach", "--name", "stale-child", "registry.k8s.io/pause:3.10")
			Expect(err).NotTo(HaveOccurred())
			_, err = docker("network", "create", "stale-network")
			Expect(err).NotTo(HaveOccurred())
			cachedImageID, err := docker("image", "inspect", "--format", "{{.Id}}", "busybox:1.37")
			Expect(err).NotTo(HaveOccurred())
			_, err = docker("rm", "--force", "buildkite-agent")
			Expect(err).NotTo(HaveOccurred())
			Eventually(func(g Gomega) {
				output, err := docker("ps", "--all", "--quiet", "--filter", "name=stale-child")
				g.Expect(err).NotTo(HaveOccurred())
				g.Expect(output).To(BeEmpty())
				output, err = docker("network", "ls", "--quiet", "--filter", "name=stale-network")
				g.Expect(err).NotTo(HaveOccurred())
				g.Expect(output).To(BeEmpty())
			}, time.Minute, time.Second).Should(Succeed())
			output, err = docker("image", "inspect", "--format", "{{.Id}}", "busybox:1.37")
			Expect(err).NotTo(HaveOccurred())
			Expect(output).To(Equal(cachedImageID))
			output, err = docker("run", "--rm", "--volume", "/workspace:/workspace",
				"busybox:1.37", "cat", "/workspace/e2e.txt")
			Expect(err).NotTo(HaveOccurred())
			Expect(output).To(Equal("workspace-ok"))

			By("gracefully terminating and garbage collecting the runner Pod")
			cmd = exec.Command("kubectl", "delete", "runnerpool/e2e-pool", "-n", poolNamespace)
			_, err = utils.Run(cmd)
			Expect(err).NotTo(HaveOccurred(), "Failed to delete the RunnerPool")
			cmd = exec.Command("kubectl", "wait", "pod/"+agentPodName, "--for=delete",
				"-n", poolNamespace, "--timeout=45s")
			_, err = utils.Run(cmd)
			Expect(err).NotTo(HaveOccurred(), "Runner Pod did not terminate within its grace period")

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
