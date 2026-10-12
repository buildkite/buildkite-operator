package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	coreclient "k8s.io/client-go/kubernetes/typed/core/v1"
	"k8s.io/client-go/rest"
)

const testImage = "public.ecr.aws/docker/library/alpine:3.20"

func testPuller(t *testing.T, api, registry http.HandlerFunc) *puller {
	t.Helper()
	apiServer := httptest.NewServer(api)
	t.Cleanup(apiServer.Close)
	registryServer := httptest.NewServer(registry)
	t.Cleanup(registryServer.Close)
	client, err := coreclient.NewForConfig(&rest.Config{
		Host: apiServer.URL, ContentConfig: rest.ContentConfig{ContentType: "application/json"},
	})
	if err != nil {
		t.Fatal(err)
	}
	p, err := newPuller(testImage, "node-a", registryServer.URL, client.Pods("test"))
	if err != nil {
		t.Fatal(err)
	}
	p.timeout = 2 * time.Second
	return p
}

func writeJSON(t *testing.T, w http.ResponseWriter, body any) {
	t.Helper()
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(body); err != nil {
		t.Error(err)
	}
}

func assertResponse(t *testing.T, response *httptest.ResponseRecorder, status int, redirect string) {
	t.Helper()
	if response.Code != status || response.Header().Get("X-Accel-Redirect") != redirect {
		t.Errorf("response = (%d, %q), want (%d, %q)",
			response.Code, response.Header().Get("X-Accel-Redirect"), status, redirect)
	}
}

func TestConcurrentMissesWaitForPodAndSpegel(t *testing.T) {
	var podReady, registryReady atomic.Bool
	var creates atomic.Int32
	created := make(chan corev1.Pod, 1)
	probed := make(chan struct{}, 1)
	p := testPuller(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			var pod corev1.Pod
			if err := json.NewDecoder(r.Body).Decode(&pod); err != nil {
				t.Error(err)
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			creates.Add(1)
			created <- pod
			writeJSON(t, w, pod)
			return
		}
		pod := corev1.Pod{}
		if podReady.Load() {
			pod.Status.Conditions = []corev1.PodCondition{{Type: corev1.PodReady, Status: corev1.ConditionTrue}}
		}
		writeJSON(t, w, pod)
	}, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodHead || r.URL.Query().Get("ns") != "public.ecr.aws" {
			t.Errorf("unexpected Spegel probe: %s %s", r.Method, r.URL)
		}
		select {
		case probed <- struct{}{}:
		default:
		}
		if !registryReady.Load() {
			w.WriteHeader(http.StatusNotFound)
		}
	})
	responses := make(chan *httptest.ResponseRecorder, 2)
	for _, method := range []string{http.MethodHead, http.MethodGet} {
		go func() {
			response := httptest.NewRecorder()
			p.ServeHTTP(response, httptest.NewRequest(method, p.path+"?test=query", nil))
			responses <- response
		}()
	}
	select {
	case pod := <-created:
		if pod.Spec.NodeName != "node-a" || pod.Spec.Containers[0].Image != testImage ||
			pod.Spec.AutomountServiceAccountToken == nil || *pod.Spec.AutomountServiceAccountToken {
			t.Errorf("unexpected fill Pod: %+v", pod.Spec)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("no fill Pod created")
	}
	select {
	case <-responses:
		t.Fatal("request completed before the Pod was ready")
	default:
	}
	podReady.Store(true)
	select {
	case <-probed:
	case <-time.After(3 * time.Second):
		t.Fatal("Spegel was not probed after the Pod became ready")
	}
	select {
	case <-responses:
		t.Fatal("request completed before Spegel could serve the manifest")
	default:
	}
	registryReady.Store(true)
	for range 2 {
		select {
		case response := <-responses:
			assertResponse(t, response, http.StatusOK, "@spegel_retry")
		case <-time.After(3 * time.Second):
			t.Fatal("waiting request did not complete")
		}
	}
	if creates.Load() != 1 {
		t.Errorf("created %d Pods, want one", creates.Load())
	}
}

func TestOtherRequestsDoNotFill(t *testing.T) {
	unexpected := func(http.ResponseWriter, *http.Request) { t.Error("unexpected cache fill") }
	p := testPuller(t, unexpected, unexpected)
	for _, path := range []string{"/v2/other/manifests/latest", "/v2/docker/library/alpine/blobs/sha256:abc", "/v2/"} {
		response := httptest.NewRecorder()
		p.ServeHTTP(response, httptest.NewRequest(http.MethodHead, path, nil))
		assertResponse(t, response, http.StatusOK, "@upstream")
	}
	response := httptest.NewRecorder()
	p.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	assertResponse(t, response, http.StatusOK, "")
}

func TestFailedOrTimedOutFillFallsBack(t *testing.T) {
	const queuedFill = "queued fill"
	for _, scenario := range []string{"API failure", "Pod not ready", "Spegel not ready", queuedFill} {
		t.Run(scenario, func(t *testing.T) {
			p := testPuller(t, func(w http.ResponseWriter, r *http.Request) {
				if scenario == queuedFill {
					t.Error("queued request should not call the API")
				}
				if scenario == "API failure" {
					w.WriteHeader(http.StatusForbidden)
					return
				}
				pod := corev1.Pod{}
				if scenario == "Spegel not ready" {
					pod.Status.Conditions = []corev1.PodCondition{{Type: corev1.PodReady, Status: corev1.ConditionTrue}}
				}
				writeJSON(t, w, pod)
			}, func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNotFound) })
			p.timeout = 30 * time.Millisecond
			if scenario == queuedFill {
				p.lock <- struct{}{}
			}
			response := httptest.NewRecorder()
			p.ServeHTTP(response, httptest.NewRequest(http.MethodHead, p.path, nil))
			assertResponse(t, response, http.StatusServiceUnavailable, "")
		})
	}
}

func TestExistingFillPodIsReused(t *testing.T) {
	p := testPuller(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusConflict)
			writeJSON(t, w, metav1.Status{Status: "Failure", Reason: metav1.StatusReasonAlreadyExists, Code: 409})
			return
		}
		writeJSON(t, w, corev1.Pod{Status: corev1.PodStatus{
			Conditions: []corev1.PodCondition{{Type: corev1.PodReady, Status: corev1.ConditionTrue}},
		}})
	}, func(http.ResponseWriter, *http.Request) {})
	response := httptest.NewRecorder()
	p.ServeHTTP(response, httptest.NewRequest(http.MethodGet, p.path, nil))
	assertResponse(t, response, http.StatusOK, "@spegel_retry")
}
