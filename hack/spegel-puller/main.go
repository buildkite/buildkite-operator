// Wait for a Pod to populate the configured public ECR image on a Spegel node.
package main

import (
	"context"
	"crypto/sha256"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/wait"
	coreclient "k8s.io/client-go/kubernetes/typed/core/v1"
	"k8s.io/client-go/rest"
	"k8s.io/utils/ptr"
)

const serviceAccountDir = "/var/run/secrets/kubernetes.io/serviceaccount"

type puller struct {
	image, node, name, path, registry string
	pods                              coreclient.PodInterface
	client                            *http.Client
	lock                              chan struct{}
	created                           bool
	timeout                           time.Duration
}

func newPuller(image, node, registry string, pods coreclient.PodInterface) (*puller, error) {
	repository, tag, tagged := strings.Cut(strings.TrimPrefix(image, "public.ecr.aws/"), ":")
	if !strings.HasPrefix(image, "public.ecr.aws/") || strings.Contains(image, "@") ||
		!tagged || repository == "" || tag == "" || node == "" || registry == "" {
		return nil, fmt.Errorf("this experiment requires a tagged public ECR image, node and Spegel registry")
	}
	digest := sha256.Sum256([]byte(image))
	return &puller{
		image: image, node: node,
		name:     fmt.Sprintf("spegel-fill-%x", digest[:8]),
		path:     "/v2/" + repository + "/manifests/" + tag,
		registry: strings.TrimRight(registry, "/"), pods: pods,
		client: &http.Client{Timeout: 5 * time.Second},
		lock:   make(chan struct{}, 1), timeout: 120 * time.Second,
	}, nil
}

func (p *puller) fill(ctx context.Context) error {
	// Include time queued behind another miss in the request's deadline.
	ctx, cancel := context.WithTimeout(ctx, p.timeout)
	defer cancel()
	select {
	case p.lock <- struct{}{}:
		defer func() { <-p.lock }()
	case <-ctx.Done():
		return ctx.Err()
	}
	if !p.created {
		pod := &corev1.Pod{
			ObjectMeta: metav1.ObjectMeta{Name: p.name, Labels: map[string]string{"app": "spegel-fill"}},
			Spec: corev1.PodSpec{
				NodeName: p.node, AutomountServiceAccountToken: ptr.To(false),
				RestartPolicy: corev1.RestartPolicyNever, TerminationGracePeriodSeconds: ptr.To(int64(1)),
				Containers: []corev1.Container{{
					Name: "image", Image: p.image, ImagePullPolicy: corev1.PullAlways,
					Command: []string{"sleep", "3600"},
					Resources: corev1.ResourceRequirements{Requests: corev1.ResourceList{
						corev1.ResourceCPU: resource.MustParse("10m"), corev1.ResourceMemory: resource.MustParse("8Mi"),
					}},
				}},
			},
		}
		_, err := p.pods.Create(ctx, pod, metav1.CreateOptions{})
		if err != nil && !apierrors.IsAlreadyExists(err) {
			return err
		}
		if err == nil {
			slog.Info("Started cache fill", "event", "fill_started", "image", p.image)
		}
		p.created = true
	}

	err := wait.PollUntilContextCancel(ctx, 200*time.Millisecond, true, func(ctx context.Context) (bool, error) {
		pod, err := p.pods.Get(ctx, p.name, metav1.GetOptions{})
		if err != nil {
			return false, err
		}
		for _, condition := range pod.Status.Conditions {
			if condition.Type == corev1.PodReady && condition.Status == corev1.ConditionTrue {
				return p.manifestReady(ctx)
			}
		}
		return false, nil
	})
	if err == nil {
		slog.Info("Completed cache fill", "event", "fill_ready", "image", p.image)
	}
	return err
}

func (p *puller) manifestReady(ctx context.Context) (bool, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodHead, p.registry+p.path+"?ns=public.ecr.aws", nil)
	if err != nil {
		return false, err
	}
	response, err := p.client.Do(request)
	if err != nil {
		return false, nil // Spegel may still be indexing the new content.
	}
	defer func() { _ = response.Body.Close() }()
	return response.StatusCode == http.StatusOK, nil
}

func (p *puller) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	if r.URL.Path != "/healthz" {
		target := "@upstream"
		if r.URL.Path == p.path {
			if err := p.fill(r.Context()); err != nil {
				slog.Error("Failed to fill cache", "event", "fill_failed", "error", err)
				w.WriteHeader(http.StatusServiceUnavailable)
				return
			}
			target = "@spegel_retry"
		}
		w.Header().Set("X-Accel-Redirect", target)
	}
	w.Header().Set("Content-Length", "0")
	w.WriteHeader(http.StatusOK)
}

func run() error {
	config, err := rest.InClusterConfig()
	if err != nil {
		return err
	}
	config.Timeout = 5 * time.Second
	client, err := coreclient.NewForConfig(config)
	if err != nil {
		return err
	}
	namespace, err := os.ReadFile(serviceAccountDir + "/namespace")
	if err != nil {
		return err
	}
	p, err := newPuller(os.Getenv("WARM_IMAGE"), os.Getenv("WARM_NODE"), os.Getenv("SPEGEL_REGISTRY"),
		client.Pods(strings.TrimSpace(string(namespace))))
	if err != nil {
		return err
	}
	server := &http.Server{Addr: ":8080", Handler: p, ReadHeaderTimeout: 5 * time.Second}
	return server.ListenAndServe()
}

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))
	if err := run(); err != nil {
		slog.Error("Puller stopped", "error", err)
		os.Exit(1)
	}
}
