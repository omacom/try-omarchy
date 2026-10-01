#!/usr/bin/env python3
"""Verify that paused or failed VMs cannot produce plausible idle reports."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/profile-process.py"


class ProfileTests(unittest.TestCase):
    def run_profile(self, statuses, event=None, malformed=False):
        with tempfile.TemporaryDirectory(prefix="profile-qmp-", dir="/tmp") as directory:
            path = Path(directory) / "qmp.sock"
            output = Path(directory) / "profile.json"
            output.write_text("previous measurement\n")
            server = socket.socket(socket.AF_UNIX)
            server.bind(str(path))
            server.listen(1)
            server.settimeout(5)
            failures = []

            def respond():
                try:
                    with server.accept()[0] as client, client.makefile("rwb") as stream:
                        stream.write(b'{"QMP":{"version":{},"capabilities":[]}}\n')
                        stream.flush()
                        checks = 0
                        for line in stream:
                            request = json.loads(line)
                            response = {}
                            if request["execute"] == "query-status":
                                if malformed:
                                    stream.write(b"invalid JSON\n")
                                    stream.flush()
                                    break
                                if event and checks == 1:
                                    stream.write((json.dumps({"event": event}) + "\n").encode())
                                state = statuses[min(checks, len(statuses) - 1)]
                                response = {"status": state, "running": state == "running"}
                                checks += 1
                            else:
                                assert request["execute"] == "qmp_capabilities"
                            stream.write((json.dumps({"return": response, "id": request["id"]}) + "\n").encode())
                            stream.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass  # The collector intentionally closes after detecting an invalid sample.
                except Exception as error:
                    failures.append(error)

            thread = threading.Thread(target=respond, daemon=True)
            thread.start()
            try:
                result = subprocess.run([
                    sys.executable, str(SCRIPT), "--pid", str(os.getpid()),
                    "--seconds", ".08", "--interval", ".02", "--qmp", str(path),
                    "--output", str(output),
                ], capture_output=True, text=True, timeout=10)
                thread.join(5)
                self.assertFalse(thread.is_alive())
                self.assertEqual(failures, [])
                return result, output.read_text()
            finally:
                server.close()

    def test_running_vm(self):
        result, output = self.run_profile(["running"])
        self.assertEqual(result.returncode, 0, result.stderr)
        profile = json.loads(output)
        self.assertTrue(profile["qmp_state_checked"])
        self.assertGreaterEqual(len(profile["samples"]), 1)
        self.assertEqual(json.loads(result.stdout), profile)

    def test_stopped_vm_does_not_overwrite_previous_measurement(self):
        for states in (["io-error"], ["running", "paused"], ["running", "io-error"]):
            with self.subTest(states=states):
                result, output = self.run_profile(states)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("not running normally", result.stderr)
                self.assertEqual(output, "previous measurement\n")

    def test_transient_vm_stop_is_not_hidden_by_later_running_status(self):
        for event in ("STOP", "BLOCK_IO_ERROR", "RESET", "SUSPEND"):
            with self.subTest(event=event):
                result, output = self.run_profile(["running"], event=event)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"VM event {event}", result.stderr)
                self.assertEqual(output, "previous measurement\n")

    def test_malformed_qmp(self):
        result, output = self.run_profile(["running"], malformed=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid QMP message", result.stderr)
        self.assertEqual(output, "previous measurement\n")


if __name__ == "__main__":
    unittest.main()
