#!/usr/bin/env python3

# Load the standard library tools used to publish and verify the chart.
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request


# Set the registry, repository, and local chart directory.
REGISTRY = "registry-1.docker.io"
REPOSITORY = "buildkite/buildkite-operator-chart"
CHART = "charts/buildkite-operator"


def publish():
    # Require a release tag containing a stable chart version.
    tag = os.environ.get("BUILDKITE_TAG", "")
    if not re.fullmatch(r"chart-v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag):
        raise ValueError("Release tag must be chart-v<major>.<minor>.<patch>")

    # Prevent pull request builds from publishing charts.
    if os.environ.get("BUILDKITE_PULL_REQUEST", "false") != "false":
        raise ValueError("Pull request builds cannot publish charts")

    # Check that the release tag matches the version in Chart.yaml.
    version = tag.removeprefix("chart-v")
    metadata = subprocess.run(
        ["helm", "show", "chart", CHART], check=True, capture_output=True, text=True
    ).stdout
    chart_version = re.search(r"^version: (.+)$", metadata, re.MULTILINE).group(1).strip("\"'")
    if chart_version != version:
        raise ValueError(f"Tag version {version} does not match Chart.yaml version {chart_version}")

    # Sign in as the Buildkite organization on Docker Hub.
    username = "buildkite"

    # Read the Docker Hub organization token from Buildkite Secrets.
    password = subprocess.run(
        ["buildkite-agent", "secret", "get", "DOCKERHUB_TOKEN"],
        check=True, capture_output=True, text=True,
    ).stdout.strip()

    # Exchange the publishing credentials for a registry access token.
    credentials = base64.b64encode(f"{username}:{password}".encode()).decode()
    request = urllib.request.Request(
        f"https://auth.docker.io/token?service=registry.docker.io&scope=repository:{REPOSITORY}:pull,push",
        headers={"Authorization": f"Basic {credentials}"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        token = json.load(response)["token"]

    # Check whether this chart version has already been published.
    request = urllib.request.Request(
        f"https://{REGISTRY}/v2/{REPOSITORY}/manifests/{version}", method="HEAD",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.oci.image.manifest.v1+json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30):
            pass
    except urllib.error.HTTPError as error:
        # Continue only when the registry reports that the version is missing.
        if error.code != 404:
            raise
    else:
        # Refuse to replace an existing release.
        raise ValueError(f"Chart version {version} already exists; refusing to overwrite it")

    # Keep credentials and chart packages in a directory that is cleaned up on exit.
    with tempfile.TemporaryDirectory(prefix="publish-chart-") as directory:
        root = Path(directory)
        env = dict(os.environ, HELM_REGISTRY_CONFIG=str(root / "registry.json"))

        # Keep Helm from saving credentials in the agent's native credential store.
        (root / "registry.json").write_text(json.dumps({"auths": {REGISTRY: {}}}))

        # Sign Helm in without putting the password in command arguments.
        subprocess.run(
            ["helm", "registry", "login", REGISTRY, "--username", username, "--password-stdin"],
            input=password, text=True, check=True, env=env,
        )

        # Package the local chart into a versioned archive.
        subprocess.run(["helm", "package", CHART, "--destination", directory], check=True, env=env)
        archive = root / f"buildkite-operator-chart-{version}.tgz"

        # Upload the chart archive to Docker Hub.
        result = subprocess.run(
            ["helm", "push", str(archive), f"oci://{REGISTRY}/buildkite"],
            check=True, capture_output=True, text=True, env=env,
        )

        # Print the upload result and read the published digest.
        output = result.stdout + result.stderr
        print(output, end="", flush=True)
        digest = re.search(r"Digest:\s+(sha256:[0-9a-f]{64})", output).group(1)
        reference = f"oci://{REGISTRY}/{REPOSITORY}@{digest}"

        # Download the published chart by digest into a separate directory.
        verification = root / "verification"
        verification.mkdir()
        subprocess.run(
            ["helm", "pull", reference, "--destination", str(verification)], check=True, env=env
        )

        # Check that the downloaded archive matches the original package.
        downloaded, = verification.glob("*.tgz")
        if hashlib.sha256(archive.read_bytes()).digest() != hashlib.sha256(downloaded.read_bytes()).digest():
            raise ValueError("Downloaded chart does not match the published package")

        # Print the verified chart reference for use in deployments.
        print(f"Verified {reference}")


# Run the publisher when this file is executed directly.
if __name__ == "__main__":
    try:
        publish()
    except subprocess.CalledProcessError as error:
        # Show the failed command's error output and return its exit status.
        if error.stderr:
            print(error.stderr, file=sys.stderr)
        sys.exit(error.returncode)
