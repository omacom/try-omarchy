from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


GUEST = Path(__file__).resolve().parents[1]
PATCH = GUEST / "patches/omarchy/1password-arm64-installer.patch"
CURRENT = "com.onepassword.OnePassword.desktop"
LEGACY = "1password.desktop"


class OnePasswordDesktopEntryTests(unittest.TestCase):
    def run_installer_tail(self, directory: Path, *, sed_fails: bool = False):
        # Execute the actual post-install rewrite and CLI install from the patch.
        # Only redirect desktop files into the fixture and stub privilege/CLI calls.
        additions = "\n".join(
            line[1:] for line in PATCH.read_text().splitlines()
            if line.startswith("+") and not line.startswith("+++")
        )
        tail = additions.split("  sudo chmod 755 /usr/local/bin/1password\n", 1)[1]
        tail = tail.split("\n}", 1)[0]
        tail = tail.replace("/usr/share/applications/", '"${DESKTOP_DIR}/"')
        script = r'''
set -euo pipefail
sudo() {
  [[ $1 == sed ]] || return 99
  if [[ $SED_FAILS == 1 ]]; then return 42; fi
  # The guest uses GNU sed; macOS sed requires an explicit backup suffix.
  if [[ $(uname -s) == Darwin && $2 == -i ]]; then
    shift 2
    sed -i '' "$@"
  else
    "$@"
  fi
}
yay() { printf '%s\n' "$*" > "$DESKTOP_DIR/cli-installed"; }
install_tail() {
  local desktop desktop_found=0 gpg_home="$DESKTOP_DIR/gnupg"
'''+ tail + r'''
}
install_tail
echo continued
'''
        return subprocess.run(
            ["bash", "-c", script],
            env={**os.environ, "DESKTOP_DIR": str(directory), "SED_FAILS": str(int(sed_fails))},
            text=True, capture_output=True,
        )

    def test_supported_entries_use_wrapper_and_installation_continues(self):
        for names in ((CURRENT,), (LEGACY,), (CURRENT, LEGACY)):
            with self.subTest(names=names), tempfile.TemporaryDirectory(prefix="1password test ") as temporary:
                directory = Path(temporary)
                original = "[Desktop Entry]\nName=1Password\nExec=/opt/1Password/1password %U\nIcon=1password\n"
                for name in names:
                    (directory / name).write_text(original)
                unrelated = directory / "another-app.desktop"
                unrelated.write_text("Exec=another-app\n")
                result = self.run_installer_tail(directory)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("continued", result.stdout)
                self.assertIn("1password-cli", (directory / "cli-installed").read_text())
                for name in names:
                    self.assertEqual(
                        (directory / name).read_text(),
                        original.replace("Exec=/opt/1Password/1password %U", "Exec=/usr/local/bin/1password %U"),
                    )
                self.assertEqual(unrelated.read_text(), "Exec=another-app\n")
                self.assertEqual(
                    sorted(path.name for path in directory.glob("*.desktop")),
                    sorted((*names, unrelated.name)),
                )

    def test_missing_desktop_entry_reports_error_and_stops(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            result = self.run_installer_tail(directory)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("did not provide a supported desktop entry", result.stderr)
            self.assertNotIn("continued", result.stdout)
            self.assertFalse((directory / "cli-installed").exists())

    def test_failed_rewrite_stops_before_cli_install(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / CURRENT).write_text("Exec=/opt/1Password/1password %U\n")
            result = self.run_installer_tail(directory, sed_fails=True)
            self.assertEqual(result.returncode, 42)
            self.assertFalse((directory / "cli-installed").exists())
            self.assertNotIn("continued", result.stdout)


if __name__ == "__main__":
    unittest.main()
