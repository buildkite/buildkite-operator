"""Prefer removing idle agents during scale-in (best effort, not a drain).

Busy agents get a pod-deletion-cost, which the ReplicaSet uses to pick scale-in
victims, and are marked not safe to evict, which stops Cluster Autoscaler from
removing their node.
"""

import json
import os
import signal
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


DELETION_COST = "controller.kubernetes.io/pod-deletion-cost"
SAFE_TO_EVICT = "cluster-autoscaler.kubernetes.io/safe-to-evict"
TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
CA_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"


def agent_busy():
    with urllib.request.urlopen("http://127.0.0.1:8080/status.json", timeout=2) as response:
        status = json.loads(response.read(4096))["aggregate_status"]
    if status == "idle":
        return False
    if status == "busy":
        return True
    raise ValueError(f"unknown agent status: {status}")


def annotations(busy):
    if busy:
        return {DELETION_COST: "100", SAFE_TO_EVICT: "false"}
    # Removing the cost restores Kubernetes' implicit cost of 0. Idle Pods need
    # an explicit "true": Cluster Autoscaler won't remove a node running Pods
    # with disk-backed emptyDir volumes by default.
    return {DELETION_COST: None, SAFE_TO_EVICT: "true"}


def patch_annotations(values):
    namespace = urllib.parse.quote(os.environ["POD_NAMESPACE"], safe="")
    name = urllib.parse.quote(os.environ["POD_NAME"], safe="")
    host = os.environ["KUBERNETES_SERVICE_HOST"]
    port = os.environ["KUBERNETES_SERVICE_PORT_HTTPS"]
    url = f"https://{host}:{port}/api/v1/namespaces/{namespace}/pods/{name}"
    with open(TOKEN_PATH, encoding="utf-8") as token:
        authorization = f"Bearer {token.read().strip()}"
    body = json.dumps({"metadata": {"annotations": values}}).encode()
    request = urllib.request.Request(
        url, data=body, method="PATCH",
        headers={"Authorization": authorization, "Content-Type": "application/merge-patch+json"},
    )
    with urllib.request.urlopen(request, context=ssl.create_default_context(cafile=CA_PATH), timeout=3):
        pass


def run():
    applied = object()  # Reconcile on startup, including after a sidecar restart.
    while True:
        try:
            busy = agent_busy()
        except (urllib.error.URLError, TimeoutError, ValueError, KeyError) as error:
            print(f"Agent status unavailable; preferring retention: {error}", flush=True)
            busy = True

        if busy != applied:
            try:
                patch_annotations(annotations(busy))
            except (urllib.error.URLError, TimeoutError, OSError) as error:
                print(f"Could not update scale-in annotations; retrying: {error}", flush=True)
            else:
                print(f"Marked Pod {'busy' if busy else 'idle'}", flush=True)
                applied = busy
        time.sleep(1)


if __name__ == "__main__":
    # The chart's shell wrapper exits on SIGTERM even before this handler is
    # installed; this keeps the script responsive when run directly.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    run()
