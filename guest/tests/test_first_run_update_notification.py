from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


GUEST = Path(__file__).resolve().parents[1]
MODULE = importlib.util.spec_from_file_location(
    "backports", GUEST / "scripts/apply-omarchy-backports.py"
)
backports = importlib.util.module_from_spec(MODULE)
MODULE.loader.exec_module(backports)


class FirstRunUpdateNotificationTests(unittest.TestCase):
    def run_first_run(self, *, try_omarchy=True, online=True, reconnect=True):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            spec = json.loads((GUEST / "spec.json").read_text())
            backport = next(b for b in spec["authenticity"]["backports"]
                            if b["id"] == "first-run-update-notification")
            omarchy = root / "usr/share/omarchy"
            command = omarchy / backport["targets"][0]["path"]
            command.parent.mkdir(parents=True)
            command.write_bytes((GUEST / "tests/fixtures/first-run-wifi.sh").read_bytes())
            backports.apply_backport(GUEST, root, omarchy, backport)
            marker = root / "build-spec.json"
            if try_omarchy:
                marker.touch()
            # Execute the complete first-run script, redirecting only its guest
            # identity check and stubbing network and desktop side effects.
            script = command.read_text().replace(
                "/usr/share/try-omarchy/build-spec.json", str(marker)
            )
            stubs = '''
nm-online() {
  case "$*" in
    *"-s"*) return 0 ;;
    *"-x"*) return "$OFFLINE" ;;
    *) return "$NO_RECONNECT" ;;
  esac
}
omarchy-notification-send() { printf '%s\n' "$*"; }
'''
            result = subprocess.run(
                ["bash", "-c", stubs + script + "\nwait\n"],
                env={**os.environ, "OFFLINE": str(int(not online)),
                     "NO_RECONNECT": str(int(not reconnect))},
                text=True, capture_output=True, check=True, timeout=5,
            )
            return result.stdout

    def test_online_guest_invites_package_updates_and_optional_setup(self):
        self.assertEqual(
            self.run_first_run(),
            "-u normal -g  Update packages and finish setup "
            "Update supported Linux packages and discover optional features such as dictation. "
            "--exec omarchy-launch-floating-terminal-with-presentation omarchy-update\n",
        )

    def test_wifi_invitation_survives_reconnection(self):
        output = self.run_first_run(online=False)
        self.assertIn("Setup Wi-Fi", output)
        self.assertIn("omarchy-shell shell toggle omarchy.network", output)
        self.assertIn("Update packages and finish setup", output)
        self.assertNotIn("Update System", output)

    def test_offline_guest_still_invites_wifi_setup(self):
        output = self.run_first_run(online=False, reconnect=False)
        self.assertIn("Setup Wi-Fi", output)
        self.assertNotIn("Update packages and finish setup", output)
        self.assertNotIn("Update System", output)

    def test_non_try_omarchy_keeps_upstream_invitation(self):
        output = self.run_first_run(try_omarchy=False)
        self.assertIn("Update System", output)
        self.assertIn("omarchy-launch-floating-terminal-with-presentation omarchy-update", output)


if __name__ == "__main__":
    unittest.main()
