import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import unittest
from unittest import mock
import urllib.error


spec = importlib.util.spec_from_file_location(
    "publish_chart", Path(__file__).resolve().parents[1] / ".buildkite/publish-chart.py"
)
publish_chart = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publish_chart)
REAL_RUN = subprocess.run
DIGEST = "sha256:" + "a" * 64


class PublishChartTest(unittest.TestCase):
    def setUp(self):
        self.registry = {}
        self.manifest_status = 404
        self.token_status = 200
        self.corrupt_download = False
        self.push_failure = False
        self.secret_reads = []
        self.credentials = []
        self.version = REAL_RUN(
            ["helm", "show", "chart", "charts/buildkite-operator"],
            check=True, capture_output=True, text=True,
        ).stdout.split("\nversion: ")[1].strip().strip("\"'")
        self.enterContext(mock.patch.dict(os.environ, {
            "BUILDKITE_TAG": f"chart-v{self.version}", "BUILDKITE_PULL_REQUEST": "false",
        }))
        self.enterContext(mock.patch.object(publish_chart.subprocess, "run", side_effect=self.command))
        self.enterContext(mock.patch.object(publish_chart.urllib.request, "urlopen", side_effect=self.request))
        self.output = self.enterContext(contextlib.redirect_stdout(io.StringIO()))

    def command(self, args, **kwargs):
        if args[0] == "buildkite-agent":
            self.secret_reads.append(args[-1])
            value = {"DOCKERHUB_USERNAME": "publisher", "DOCKERHUB_TOKEN": "test-private-password"}[args[-1]]
            return subprocess.CompletedProcess(args, 0, stdout=value + "\n")
        if args[1:3] == ["registry", "login"]:
            self.assertEqual(kwargs["input"], "test-private-password")
            self.assertNotIn("test-private-password", " ".join(args))
            config = Path(kwargs["env"]["HELM_REGISTRY_CONFIG"])
            config.write_text('{"auths": {}}')
            self.credentials.append(config)
        elif args[1] == "push":
            if self.push_failure:
                raise subprocess.CalledProcessError(1, args, stderr="registry unavailable")
            self.registry[args[3] + "/buildkite-operator-chart@" + DIGEST] = Path(args[2]).read_bytes()
            return subprocess.CompletedProcess(args, 0, stdout="", stderr=f"Digest: {DIGEST}\n")
        elif args[1] == "pull":
            archive = self.registry[args[2]]
            if self.corrupt_download:
                archive += b"corrupt"
            filename = f"buildkite-operator-chart@sha256-{DIGEST.removeprefix('sha256:')}.tgz"
            (Path(args[4]) / filename).write_bytes(archive)
        else:
            return REAL_RUN(args, **kwargs)
        return subprocess.CompletedProcess(args, 0)

    def request(self, request, **kwargs):
        if request.full_url.startswith("https://auth.docker.io/token?"):
            self.assertEqual(request.full_url,
                             "https://auth.docker.io/token?service=registry.docker.io&scope=repository:buildkite/buildkite-operator-chart:pull,push")
            self.assertEqual(
                request.get_header("Authorization"),
                "Basic cHVibGlzaGVyOnRlc3QtcHJpdmF0ZS1wYXNzd29yZA==",
            )
            status = self.token_status
            result = {"token": "test-registry-token"}
        else:
            self.assertEqual(request.full_url,
                             f"https://registry-1.docker.io/v2/buildkite/buildkite-operator-chart/manifests/{self.version}")
            self.assertEqual(request.get_method(), "HEAD")
            self.assertEqual(request.get_header("Authorization"), "Bearer test-registry-token")
            status = self.manifest_status
            result = {}
        if status != 200:
            raise urllib.error.HTTPError(request.full_url, status, "Registry error", {}, None)
        return io.BytesIO(json.dumps(result).encode())

    def test_publish_and_verify_real_chart_package(self):
        publish_chart.publish()
        self.assertEqual(len(self.registry), 1)
        self.assertIn(f"Verified oci://registry-1.docker.io/buildkite/buildkite-operator-chart@{DIGEST}", self.output.getvalue())
        self.assertNotIn("test-private-password", self.output.getvalue())
        self.assertTrue(self.credentials)
        self.assertTrue(all(not path.parent.exists() for path in self.credentials))

    def test_reject_invalid_tags_and_mismatched_version_before_reading_secrets(self):
        for tag in ("", "v0.18.0", "chart-v01.2.3", "chart-v0.18.0-rc.1", "chart-v999.0.0"):
            with self.subTest(tag=tag), mock.patch.dict(os.environ, {"BUILDKITE_TAG": tag}):
                with self.assertRaises(ValueError):
                    publish_chart.publish()
        self.assertEqual(self.secret_reads, [])
        self.assertEqual(self.registry, {})

    def test_reject_pull_request_before_reading_secrets(self):
        with mock.patch.dict(os.environ, {"BUILDKITE_PULL_REQUEST": "123"}):
            with self.assertRaisesRegex(ValueError, "Pull request"):
                publish_chart.publish()
        self.assertEqual(self.secret_reads, [])

    def test_existing_version_is_not_overwritten(self):
        self.manifest_status = 200
        with self.assertRaisesRegex(ValueError, "already exists"):
            publish_chart.publish()
        self.assertEqual(self.registry, {})

    def test_registry_errors_are_not_treated_as_missing_versions(self):
        for status in (401, 403, 429, 500):
            with self.subTest(status=status):
                self.manifest_status = status
                with self.assertRaises(urllib.error.HTTPError):
                    publish_chart.publish()
                self.assertEqual(self.registry, {})
        self.token_status = 401
        with self.assertRaises(urllib.error.HTTPError):
            publish_chart.publish()
        with mock.patch.object(publish_chart.urllib.request, "urlopen", side_effect=urllib.error.URLError("offline")):
            with self.assertRaises(urllib.error.URLError):
                publish_chart.publish()
        self.assertEqual(self.registry, {})

    def test_push_failure_removes_credentials(self):
        self.push_failure = True
        with self.assertRaises(subprocess.CalledProcessError):
            publish_chart.publish()
        self.assertEqual(self.registry, {})
        self.assertTrue(all(not path.parent.exists() for path in self.credentials))

    def test_downloaded_package_must_match(self):
        self.corrupt_download = True
        with self.assertRaisesRegex(ValueError, "does not match"):
            publish_chart.publish()
        self.assertNotIn("Verified", self.output.getvalue())
        self.assertTrue(all(not path.parent.exists() for path in self.credentials))


if __name__ == "__main__":
    unittest.main()
