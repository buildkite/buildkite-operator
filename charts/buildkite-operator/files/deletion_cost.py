"""Prefer idle agents during ReplicaSet scale-in (best effort, not a drain)."""

import json
import os
import signal
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


ANNOTATION = "controller.kubernetes.io/pod-deletion-cost"
TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
CA_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"


def deletion_cost():
    with urllib.request.urlopen("http://127.0.0.1:8080/status.json", timeout=2) as response:
        status = json.loads(response.read(4096))["aggregate_status"]
    if status == "idle":
        return None  # Removing the annotation restores Kubernetes' implicit cost of 0.
    if status == "busy":
        return "100"
    raise ValueError(f"unknown agent status: {status}")


def patch_cost(cost):
    namespace = urllib.parse.quote(os.environ["POD_NAMESPACE"], safe="")
    name = urllib.parse.quote(os.environ["POD_NAME"], safe="")
    host = os.environ["KUBERNETES_SERVICE_HOST"]
    port = os.environ["KUBERNETES_SERVICE_PORT_HTTPS"]
    url = f"https://{host}:{port}/api/v1/namespaces/{namespace}/pods/{name}"
    with open(TOKEN_PATH, encoding="utf-8") as token:
        authorization = f"Bearer {token.read().strip()}"
    body = json.dumps({"metadata": {"annotations": {ANNOTATION: cost}}}).encode()
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
            cost = deletion_cost()
        except (urllib.error.URLError, TimeoutError, ValueError, KeyError) as error:
            print(f"Agent status unavailable; preferring retention: {error}", flush=True)
            cost = "100"

        if cost != applied:
            try:
                patch_cost(cost)
            except (urllib.error.URLError, TimeoutError, OSError) as error:
                print(f"Could not update deletion cost; retrying: {error}", flush=True)
            else:
                print(f"Deletion cost: {cost or 'default (idle)'}", flush=True)
                applied = cost
        time.sleep(1)


if __name__ == "__main__":
    # The chart's shell wrapper exits on SIGTERM even before this handler is
    # installed; this keeps the script responsive when run directly.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    run()
