"""Sync the OCI accelerator CA certificate from its Secret into a ConfigMap.

create copies the certificate into the ConfigMap for runner Pods to use. If the
Secret is missing, create first stores the CA that oci-accelerator init-ca
wrote to CA_DIR, or fails when CA_DIR is unset. delete removes the ConfigMap,
and the Secret when SECRET_NAME is set.
"""

import base64
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request


TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
CA_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
CERTIFICATE = "ca.crt"


def request(method, path, body=None, content_type="application/json"):
    host = os.environ["KUBERNETES_SERVICE_HOST"]
    port = os.environ["KUBERNETES_SERVICE_PORT_HTTPS"]
    with open(TOKEN_PATH, encoding="utf-8") as token:
        authorization = f"Bearer {token.read().strip()}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        f"https://{host}:{port}{path}", data=data, method=method,
        headers={"Authorization": authorization, "Content-Type": content_type},
    )
    context = ssl.create_default_context(cafile=CA_PATH)
    try:
        with urllib.request.urlopen(req, context=context, timeout=10) as response:
            return response.status, json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        return error.code, {}


def api_path(resource, name=""):
    namespace = urllib.parse.quote(os.environ["POD_NAMESPACE"], safe="")
    path = f"/api/v1/namespaces/{namespace}/{resource}"
    return f"{path}/{urllib.parse.quote(name, safe='')}" if name else path


def generate_secret(name, cert_key, private_key_key, labels):
    ca_dir = os.environ["CA_DIR"]
    data = {}
    for key, filename in ((cert_key, "ca.crt"), (private_key_key, "ca.key")):
        with open(os.path.join(ca_dir, filename), "rb") as f:
            data[key] = base64.b64encode(f.read()).decode()
    body = {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {"name": name, "labels": labels},
        "type": "Opaque",
        "data": data,
    }
    status, _ = request("POST", api_path("secrets"), body)
    if status == 201:
        print(f"Created Secret {name}", flush=True)
    elif status == 409:
        print(f"Using Secret {name} created concurrently", flush=True)
    else:
        sys.exit(f"Could not create Secret {name}: HTTP {status}")


def certificate(name, cert_key, private_key_key, labels):
    """Returns the CA certificate, generating the Secret from CA_DIR if it is missing."""
    status, secret = request("GET", api_path("secrets", name))
    if status == 404 and "CA_DIR" in os.environ:
        generate_secret(name, cert_key, private_key_key, labels)
        status, secret = request("GET", api_path("secrets", name))
    elif status == 200:
        print(f"Using existing Secret {name}", flush=True)
    if status == 404:
        sys.exit(f"Secret {name} not found; create it in the release namespace first")
    if status != 200:
        sys.exit(f"Could not read Secret {name}: HTTP {status}")
    missing = [key for key in (cert_key, private_key_key) if key not in secret.get("data", {})]
    if missing:
        hint = "; delete it to generate a new CA" if "CA_DIR" in os.environ else ""
        sys.exit(f"Secret {name} exists but has no {' or '.join(missing)}{hint}")
    return base64.b64decode(secret["data"][cert_key]).decode()


def publish(name, cert, labels):
    status, config_map = request("GET", api_path("configmaps", name))
    if status == 200:
        if config_map.get("data", {}).get(CERTIFICATE) == cert:
            print(f"ConfigMap {name} is up to date", flush=True)
            return
        status, _ = request("PATCH", api_path("configmaps", name), {"data": {CERTIFICATE: cert}},
                            content_type="application/merge-patch+json")
        if status != 200:
            sys.exit(f"Could not update ConfigMap {name}: HTTP {status}")
        print(f"Updated ConfigMap {name}", flush=True)
        return
    if status != 404:
        sys.exit(f"Could not read ConfigMap {name}: HTTP {status}")
    body = {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {"name": name, "labels": labels},
        "data": {CERTIFICATE: cert},
    }
    status, _ = request("POST", api_path("configmaps"), body)
    if status != 201:
        sys.exit(f"Could not create ConfigMap {name}: HTTP {status}")
    print(f"Created ConfigMap {name}", flush=True)


def delete(resource, kind, name):
    status, _ = request("DELETE", api_path(resource, name))
    if status in (200, 202):
        print(f"Deleted {kind} {name}", flush=True)
    elif status == 404:
        print(f"{kind} {name} was already deleted", flush=True)
    else:
        sys.exit(f"Could not delete {kind} {name}: HTTP {status}")


if __name__ == "__main__":
    config_map_name = os.environ["CONFIGMAP_NAME"]
    if sys.argv[1:] == ["create"]:
        labels = json.loads(os.environ["LABELS"])
        cert = certificate(os.environ["SECRET_NAME"], os.environ["CERTIFICATE_KEY"],
                           os.environ["PRIVATE_KEY_KEY"], labels)
        publish(config_map_name, cert, labels)
    elif sys.argv[1:] == ["delete"]:
        delete("configmaps", "ConfigMap", config_map_name)
        if "SECRET_NAME" in os.environ:
            delete("secrets", "Secret", os.environ["SECRET_NAME"])
    else:
        sys.exit("usage: oci_accelerator_ca.py create|delete")
