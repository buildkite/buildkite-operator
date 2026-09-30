import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import unittest
from unittest import mock
import urllib.error


spec = importlib.util.spec_from_file_location(
    "deletion_cost",
    Path(__file__).resolve().parents[1] / "charts/buildkite-operator/files/deletion_cost.py",
)
deletion_cost = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deletion_cost)


class DeletionCostTest(unittest.TestCase):
    def test_agent_occupancy_and_unknown_status(self):
        for status, expected in (("idle", None), ("busy", "100")):
            with self.subTest(status=status), mock.patch.object(
                deletion_cost.urllib.request, "urlopen", return_value=io.BytesIO(
                    json.dumps({"aggregate_status": status}).encode()
                )
            ):
                self.assertEqual(deletion_cost.deletion_cost(), expected)

        with mock.patch.object(
            deletion_cost.urllib.request, "urlopen", return_value=io.BytesIO(b'{"aggregate_status":"stopping"}')
        ):
            with self.assertRaises(ValueError):
                deletion_cost.deletion_cost()

    def test_patch_only_own_pod_and_remove_annotation_when_idle(self):
        env = {"POD_NAME": "runner-abc", "POD_NAMESPACE": "buildkite-learning",
               "KUBERNETES_SERVICE_HOST": "10.0.0.1", "KUBERNETES_SERVICE_PORT_HTTPS": "443"}
        with mock.patch.dict(os.environ, env), mock.patch("builtins.open", mock.mock_open(read_data="secret\n")), \
             mock.patch.object(deletion_cost.ssl, "create_default_context"), \
             mock.patch.object(deletion_cost.urllib.request, "urlopen", side_effect=lambda *args, **kwargs: io.BytesIO(b"{}")) as request:
            deletion_cost.patch_cost("100")
            deletion_cost.patch_cost(None)

        for call, expected in zip(request.call_args_list, ("100", None), strict=True):
            req = call.args[0]
            self.assertEqual(req.full_url, "https://10.0.0.1:443/api/v1/namespaces/buildkite-learning/pods/runner-abc")
            self.assertEqual(req.get_method(), "PATCH")
            self.assertEqual(req.get_header("Authorization"), "Bearer secret")
            self.assertEqual(json.loads(req.data), {"metadata": {"annotations": {
                deletion_cost.ANNOTATION: expected,
            }}})

    def test_retry_failed_patch_and_prefer_retention_on_status_error(self):
        with mock.patch.object(deletion_cost, "deletion_cost", side_effect=[
            None, None, urllib.error.URLError("unavailable"), "100", None,
        ]), mock.patch.object(deletion_cost, "patch_cost", side_effect=[
            OSError("retry"), None, None, None,
        ]) as patch, mock.patch.object(deletion_cost.time, "sleep", side_effect=[
            None, None, None, None, StopIteration,
        ]), mock.patch("builtins.print"):
            with self.assertRaises(StopIteration):
                deletion_cost.run()
        self.assertEqual(patch.call_args_list, [
            mock.call(None), mock.call(None), mock.call("100"), mock.call(None),
        ])

    def test_pid_one_style_sigterm_exits_cleanly(self):
        env = dict(os.environ, POD_NAME="runner-abc", POD_NAMESPACE="buildkite-learning",
                   KUBERNETES_SERVICE_HOST="127.0.0.1", KUBERNETES_SERVICE_PORT_HTTPS="443")
        process = subprocess.Popen([sys.executable, "-u", deletion_cost.__file__],
                                   env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            time.sleep(0.2)
            self.assertIsNone(process.poll())
            process.send_signal(signal.SIGTERM)
            self.assertEqual(process.wait(timeout=2), 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()


if __name__ == "__main__":
    unittest.main()
