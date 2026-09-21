from __future__ import annotations

import hashlib
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


class UpdateRestartARMKernelTests(unittest.TestCase):
    def run_restart(self, markers=(), *, reboot_required=False, deleted_hyprland=False):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = GUEST / "tests/fixtures/omarchy-update-restart"
            spec = json.loads((GUEST / "spec.json").read_text())
            backport = next(b for b in spec["authenticity"]["backports"]
                            if b["id"] == "update-restart-arm-kernel")
            self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(),
                             backport["targets"][0]["beforeSha256"])
            patch = GUEST / backport["patch"]
            self.assertEqual(hashlib.sha256(patch.read_bytes()).hexdigest(),
                             backport["patchSha256"])
            omarchy = root / "usr/share/omarchy"
            command = omarchy / backport["targets"][0]["path"]
            command.parent.mkdir(parents=True)
            command.write_bytes(source.read_bytes())
            # Use the build's strict git-apply path so malformed patches fail here.
            backports.apply_backport(GUEST, root, omarchy, backport)
            self.assertEqual(hashlib.sha256(command.read_bytes()).hexdigest(),
                             backport["targets"][0]["afterSha256"])
            # Redirect only the filesystem boundary; execute the complete patched
            # command with stubbed external effects, including restart fallthrough.
            script = command.read_text().replace("/usr/lib/modules/", f"{root}/modules/")
            for release, name, owned in markers:
                marker = root / "modules" / release / name
                marker.parent.mkdir(parents=True, exist_ok=True)
                marker.touch()
                if owned:
                    marker.with_name(name + ".owned").touch()
            state = root / ".local/state/omarchy"
            state.mkdir(parents=True)
            (state / "restart-test-required").touch()
            if reboot_required:
                (state / "reboot-required").touch()
            stubs = '''
uname() { echo 7.2.5-1-aarch64-ARCH; }
pacman() { [[ $1 == -Qo && -f $2.owned ]]; }
gum() { echo "PROMPT: $2"; return 1; }
omarchy-system-reboot() { echo UNEXPECTED_REBOOT; }
pgrep() { echo 123; }
readlink() { [[ $DELETED_HYPRLAND == 1 ]] && echo '/usr/bin/Hyprland (deleted)'; }
omarchy-state() { :; }
omarchy-restart-test() { echo SERVICE_RESTARTED; }
omarchy-restart-shell() { echo SHELL_RESTARTED; }
'''
            completed = subprocess.run(
                ["bash", "-c", stubs + script], capture_output=True, text=True,
                env={**os.environ, "HOME": str(root),
                     "DELETED_HYPRLAND": str(int(deleted_hyprland))},
                check=True,
            )
            self.assertIn("SERVICE_RESTARTED", completed.stdout)
            self.assertIn("SHELL_RESTARTED", completed.stdout)
            self.assertNotIn("UNEXPECTED_REBOOT", completed.stdout)
            expected_unknown = not any(owned for _, _, owned in markers)
            self.assertEqual(
                "Unable to determine kernel reboot status" in completed.stderr,
                expected_unknown,
            )
            return completed.stdout

    def test_matching_arm_modules_without_vmlinuz_do_not_prompt(self):
        output = self.run_restart([("7.2.5-1-aarch64-ARCH", "modules.builtin", True)])
        self.assertNotIn("PROMPT:", output)

    def test_newer_installed_arm_kernel_prompts(self):
        output = self.run_restart([("7.2.6-1-aarch64-ARCH", "modules.builtin", True)])
        self.assertIn("PROMPT: Linux kernel has been updated.", output)

    def test_vmlinuz_layout_still_detects_matches_and_changes(self):
        for release, updated in [("7.2.5-1-aarch64-ARCH", False), ("7.2.6-1-aarch64-ARCH", True)]:
            with self.subTest(release=release):
                output = self.run_restart([(release, "vmlinuz", True)])
                self.assertEqual("PROMPT: Linux kernel" in output, updated)

    def test_matching_arm_kernel_wins_over_other_installed_kernel(self):
        output = self.run_restart([
            ("7.2.6-1-aarch64-ARCH", "vmlinuz", True),
            ("7.2.5-1-aarch64-ARCH", "modules.builtin", True),
        ])
        self.assertNotIn("PROMPT:", output)

    def test_unknown_and_unowned_layouts_do_not_claim_an_update(self):
        for markers in [[], [("7.2.6-1-aarch64-ARCH", "modules.builtin", False)]]:
            with self.subTest(markers=markers):
                self.assertNotIn("PROMPT:", self.run_restart(markers))

    def test_stale_unowned_matching_modules_do_not_hide_a_change(self):
        output = self.run_restart([
            ("7.2.5-1-aarch64-ARCH", "modules.builtin", False),
            ("7.2.6-1-aarch64-ARCH", "modules.builtin", True),
        ])
        self.assertIn("PROMPT: Linux kernel has been updated.", output)

    def test_other_reboot_reasons_survive_unknown_kernel_layout(self):
        output = self.run_restart(reboot_required=True, deleted_hyprland=True)
        self.assertIn("PROMPT: Updates require reboot.", output)
        self.assertIn("PROMPT: Hyprland has been updated.", output)
        self.assertNotIn("PROMPT: Linux kernel", output)


if __name__ == "__main__":
    unittest.main()
