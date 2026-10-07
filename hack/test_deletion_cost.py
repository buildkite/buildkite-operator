import http.client
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
        for status, expected in (("idle", False), ("busy", True)):
            with self.subTest(status=status), mock.patch.object(
                deletion_cost.urllib.request, "urlopen", return_value=io.BytesIO(
                    json.dumps({"aggregate_status": status}).encode()
                )
            ):
                self.assertEqual(deletion_cost.agent_busy(), expected)

        with mock.patch.object(
            deletion_cost.urllib.request, "urlopen", return_value=io.BytesIO(b'{"aggregate_status":"stopping"}')
        ):
            with self.assertRaises(ValueError):
                deletion_cost.agent_busy()

    def test_patch_only_own_pod_with_both_annotations(self):
        env = {"POD_NAME": "runner-abc", "POD_NAMESPACE": "buildkite-learning",
               "KUBERNETES_SERVICE_HOST": "10.0.0.1", "KUBERNETES_SERVICE_PORT_HTTPS": "443"}
        with mock.patch.dict(os.environ, env), mock.patch("builtins.open", mock.mock_open(read_data="secret\n")), \
             mock.patch.object(deletion_cost.ssl, "create_default_context"), \
             mock.patch.object(deletion_cost.urllib.request, "urlopen", side_effect=lambda *args, **kwargs: io.BytesIO(b"{}")) as request:
            deletion_cost.patch_annotations(deletion_cost.annotations(True))
            deletion_cost.patch_annotations(deletion_cost.annotations(False))

        # Busy agents keep their node; idle agents drop the deletion cost and
        # explicitly allow eviction, which local-storage Pods need.
        expected = (
            {deletion_cost.DELETION_COST: "100", deletion_cost.SAFE_TO_EVICT: "false"},
            {deletion_cost.DELETION_COST: None, deletion_cost.SAFE_TO_EVICT: "true"},
        )
        for call, annotations in zip(request.call_args_list, expected, strict=True):
            req = call.args[0]
            self.assertEqual(req.full_url, "https://10.0.0.1:443/api/v1/namespaces/buildkite-learning/pods/runner-abc")
            self.assertEqual(req.get_method(), "PATCH")
            self.assertEqual(req.get_header("Authorization"), "Bearer secret")
            self.assertEqual(json.loads(req.data), {"metadata": {"annotations": annotations}})

    def test_patch_on_change_retry_failures_and_prefer_retention_on_status_error(self):
        busy, idle = deletion_cost.annotations(True), deletion_cost.annotations(False)
        with mock.patch.object(deletion_cost, "agent_busy", side_effect=[
            False, False, False, urllib.error.URLError("unavailable"), True, False,
        ]), mock.patch.object(deletion_cost, "patch_annotations", side_effect=[
            OSError("retry"), None, None, None,
        ]) as patch, mock.patch.object(deletion_cost.time, "sleep", side_effect=[
            None, None, None, None, None, StopIteration,
        ]), mock.patch("builtins.print"):
            with self.assertRaises(StopIteration):
                deletion_cost.run()
        self.assertEqual(patch.call_args_list, [
            mock.call(idle), mock.call(idle), mock.call(busy), mock.call(idle),
        ])

    def test_response_read_errors_prefer_retention_without_crashing(self):
        # urllib leaves errors raised while reading the response unwrapped.
        busy, idle = deletion_cost.annotations(True), deletion_cost.annotations(False)
        with mock.patch.object(deletion_cost, "agent_busy", side_effect=[
            False, ConnectionResetError(104, "Connection reset by peer"),
            http.client.IncompleteRead(b""), False, False,
        ]), mock.patch.object(deletion_cost, "patch_annotations", side_effect=[
            None, None, http.client.IncompleteRead(b""), None,
        ]) as patch, mock.patch.object(deletion_cost.time, "sleep", side_effect=[
            None, None, None, None, StopIteration,
        ]), mock.patch("builtins.print"):
            with self.assertRaises(StopIteration):
                deletion_cost.run()
        self.assertEqual(patch.call_args_list, [
            mock.call(idle), mock.call(busy), mock.call(idle), mock.call(idle),
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
