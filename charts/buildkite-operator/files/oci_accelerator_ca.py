"""Create or delete the OCI accelerator CA Secret that the chart generates.

create stores the CA that oci-accelerator init-ca wrote to CA_DIR, unless the
Secret already exists: the CA is generated once and never replaced. delete
removes the Secret when the release is uninstalled.
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


def request(method, path, body=None):
    host = os.environ["KUBERNETES_SERVICE_HOST"]
    port = os.environ["KUBERNETES_SERVICE_PORT_HTTPS"]
    with open(TOKEN_PATH, encoding="utf-8") as token:
        authorization = f"Bearer {token.read().strip()}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        f"https://{host}:{port}{path}", data=data, method=method,
        headers={"Authorization": authorization, "Content-Type": "application/json"},
    )
    context = ssl.create_default_context(cafile=CA_PATH)
    try:
        with urllib.request.urlopen(req, context=context, timeout=10) as response:
            return response.status, json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        return error.code, {}


def secrets_path(name=""):
    namespace = urllib.parse.quote(os.environ["POD_NAMESPACE"], safe="")
    path = f"/api/v1/namespaces/{namespace}/secrets"
    return f"{path}/{urllib.parse.quote(name, safe='')}" if name else path


def create(name, cert_key, private_key_key):
    status, secret = request("GET", secrets_path(name))
    if status == 200:
        missing = [key for key in (cert_key, private_key_key) if key not in secret.get("data", {})]
        if missing:
            sys.exit(f"Secret {name} exists but has no {' or '.join(missing)}; delete it to generate a new CA")
        print(f"Using existing Secret {name}", flush=True)
        return
    if status != 404:
        sys.exit(f"Could not read Secret {name}: HTTP {status}")

    ca_dir = os.environ["CA_DIR"]
    data = {}
    for key, filename in ((cert_key, "ca.crt"), (private_key_key, "ca.key")):
        with open(os.path.join(ca_dir, filename), "rb") as f:
            data[key] = base64.b64encode(f.read()).decode()
    body = {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {"name": name, "labels": json.loads(os.environ["SECRET_LABELS"])},
        "type": "Opaque",
        "data": data,
    }
    status, _ = request("POST", secrets_path(), body)
    if status == 201:
        print(f"Created Secret {name}", flush=True)
    elif status == 409:
        print(f"Using Secret {name} created concurrently", flush=True)
    else:
        sys.exit(f"Could not create Secret {name}: HTTP {status}")


def delete(name):
    status, _ = request("DELETE", secrets_path(name))
    if status in (200, 202):
        print(f"Deleted Secret {name}", flush=True)
    elif status == 404:
        print(f"Secret {name} was already deleted", flush=True)
    else:
        sys.exit(f"Could not delete Secret {name}: HTTP {status}")


if __name__ == "__main__":
    secret_name = os.environ["SECRET_NAME"]
    if sys.argv[1:] == ["create"]:
        create(secret_name, os.environ["CERTIFICATE_KEY"], os.environ["PRIVATE_KEY_KEY"])
    elif sys.argv[1:] == ["delete"]:
        delete(secret_name)
    else:
        sys.exit("usage: oci_accelerator_ca.py create|delete")
