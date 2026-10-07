import os
from pathlib import Path
import subprocess
import tempfile
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / "native-overlay/usr/local/lib/try-omarchy/install-vivaldi-arm64"


class VivaldiVerifierTests(unittest.TestCase):
    def run_verifier(self, available=(), status=0, install_commands=True):
        # Exercise the installer's actual preflight without downloading or
        # installing anything on the host running these tests.
        functions = INSTALLER.read_text().split('[[ $(uname -m) == aarch64 ]]', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            for name in available:
                (Path(directory) / name).touch()
            script = functions + r'''
command() {
  [[ -f "$TEST_DIR/$2" ]]
}
omarchy-pkg-add() {
  echo "package request: $*"
  if [[ $INSTALL_COMMANDS == yes ]]; then
    touch "$TEST_DIR/rpm" "$TEST_DIR/rpmkeys"
  fi
  return "$INSTALL_STATUS"
}
ensure_rpm_verifier
echo "verification may proceed"
'''
            return subprocess.run(
                ["bash", "-c", script], text=True, capture_output=True,
                env=dict(os.environ, TEST_DIR=directory,
                         INSTALL_STATUS=str(status),
                         INSTALL_COMMANDS="yes" if install_commands else "no"),
            )

    def test_existing_verifier_needs_no_package_install(self):
        result = self.run_verifier(available=("rpm", "rpmkeys"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("package request:", result.stdout)

    def test_missing_command_installs_verifier(self):
        result = self.run_verifier(available=("rpm",))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("package request: rpm-tools", result.stdout)
        self.assertIn("verification may proceed", result.stdout)

    def test_silent_package_failure_explains_recovery_and_stops(self):
        result = self.run_verifier(status=42, install_commands=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exited with status 42", result.stderr)
        self.assertIn("sudo pacman -S --needed rpm-tools", result.stderr)
        self.assertIn("signature verification cannot be skipped", result.stderr)
        self.assertNotIn("verification may proceed", result.stdout)

    def test_success_without_verifier_still_stops(self):
        result = self.run_verifier(available=("rpm",), install_commands=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not both available", result.stderr)
        self.assertNotIn("verification may proceed", result.stdout)


class VivaldiDiscoveryTests(unittest.TestCase):
    def run_discovery(self, listing, curl_status=0):
        functions = INSTALLER.read_text().split('follow_stable=0', 1)[0]
        script = functions + r'''
curl() {
  cat "$LISTING"
  return "$CURL_STATUS"
}
discover_latest_stable
'''
        with tempfile.TemporaryDirectory() as directory:
            listing_path = Path(directory) / "listing.html"
            listing_path.write_text(listing)
            return subprocess.run(
                ["bash", "-c", script],
                text=True,
                capture_output=True,
                env=dict(
                    os.environ,
                    LISTING=str(listing_path),
                    CURL_STATUS=str(curl_status),
                ),
            )

    def test_discovers_newest_stable_and_ignores_snapshot(self):
        listing = """
href="vivaldi-snapshot-8.3.4161.3-1.aarch64.rpm"
href="vivaldi-stable-8.2.4133.64-1.aarch64.rpm"
href="vivaldi-stable-8.2.4133.76-1.aarch64.rpm"
href="vivaldi-stable-8.2.4133.68-1.aarch64.rpm"
"""
        result = self.run_discovery(listing)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "8.2.4133.76 1")

    def test_empty_index_fails(self):
        result = self.run_discovery("href=\"../\"\nhref=\"repodata/\"\n")
        self.assertNotEqual(result.returncode, 0)

    def test_curl_failure_fails(self):
        result = self.run_discovery("vivaldi-stable-8.2.4133.76-1.aarch64.rpm", curl_status=22)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
