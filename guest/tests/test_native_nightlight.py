"""Exercise the VM night-light state transitions across the Hyprland IPC boundary."""

import json
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch


GUEST = Path(__file__).resolve().parents[1]
OVERLAY = GUEST / "native-overlay/usr/local"


class NightlightTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.helper = self.bin / "omarchy-native-nightlight"
        shutil.copy2(OVERLAY / "bin/omarchy-native-nightlight", self.helper)
        self.shader = self.root / "share/try-omarchy/nightlight.frag"
        self.shader.parent.mkdir(parents=True)
        shutil.copy2(OVERLAY / "share/try-omarchy/nightlight.frag", self.shader)
        self.state = self.root / "state.json"
        self.set_shader("[[EMPTY]]")
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        XDG_RUNTIME_DIR=str(self.root), HYPRLAND_INSTANCE_SIGNATURE="test-session",
                        NIGHTLIGHT_TEST_STATE=str(self.state))
        fake = self.bin / "hyprctl"
        fake.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys, time
path = pathlib.Path(os.environ["NIGHTLIGHT_TEST_STATE"])
args = sys.argv[1:]
mode = os.environ.get("NIGHTLIGHT_TEST_MODE")
if mode == "unavailable": sys.exit(1)
if args[0] == "getoption":
    print("not json" if mode == "malformed" else "[]" if mode == "array" else path.read_text())
elif args[0] == "eval":
    if mode == "reject":
        print("error: rejected setting")
        sys.exit(0)
    time.sleep(0.02)
    prefix = "hl.config({ decoration = { screen_shader = "
    value = json.loads(args[1][len(prefix):-len(" } })")])
    path.write_text(json.dumps({"str": value}))
    print("ok")
else: sys.exit(2)
''')
        fake.chmod(0o755)
        for name in ("omarchy-shell", "notify-send"):
            command = self.bin / name
            command.write_text("#!/bin/sh\nexit 0\n")
            command.chmod(0o755)

    def set_shader(self, value):
        self.state.write_text(json.dumps({"str": value}))

    def run_helper(self, *args, code=0, mode=""):
        result = subprocess.run([str(self.helper), *args], capture_output=True, text=True,
                                env=dict(self.env, NIGHTLIGHT_TEST_MODE=mode))
        self.assertEqual(result.returncode, code, result.stderr)
        return result

    def status(self):
        return json.loads(self.run_helper("--status").stdout)

    def test_toggle_on_and_off_tracks_the_actual_renderer(self):
        self.assertEqual(self.status(), {"enabled": False, "temperature": 6500})
        self.run_helper()
        self.assertEqual(self.status(), {"enabled": True, "temperature": 4000})
        self.run_helper()
        self.assertEqual(self.status(), {"enabled": False, "temperature": 6500})

    def test_explicit_shell_requests_are_idempotent(self):
        for temperature, enabled in (("4000", True), ("4000", True), ("6500", False), ("6500", False)):
            self.run_helper("--temperature", temperature)
            self.assertEqual(self.status()["enabled"], enabled)

    def test_custom_shader_is_preserved_when_enabling_is_refused(self):
        self.set_shader("/home/user/custom.frag")
        result = self.run_helper(code=1)
        self.assertIn("custom screen shader", result.stderr)
        self.assertEqual(json.loads(self.state.read_text())["str"], "/home/user/custom.frag")

    def test_disable_does_not_clear_a_later_user_override(self):
        self.run_helper("--temperature", "4000")
        self.set_shader("/home/user/custom.frag")
        self.run_helper("--temperature", "6500")
        self.assertEqual(json.loads(self.state.read_text())["str"], "/home/user/custom.frag")

    def test_config_reload_is_not_reported_as_still_enabled(self):
        self.run_helper()
        self.set_shader("[[EMPTY]]")
        self.assertFalse(self.status()["enabled"])

    def test_missing_shader_does_not_change_the_renderer(self):
        self.shader.unlink()
        self.run_helper(code=1)
        self.assertFalse(self.status()["enabled"])

    def test_unavailable_or_malformed_ipc_does_not_report_success(self):
        for mode in ("unavailable", "malformed", "array"):
            with self.subTest(mode=mode):
                self.run_helper(code=1, mode=mode)
                state = json.loads(self.run_helper("--status", code=1, mode=mode).stdout)
                self.assertEqual(state, {"enabled": False, "temperature": None})

    def test_rejected_setting_is_not_reported_as_enabled(self):
        self.run_helper(code=1, mode="reject")
        self.assertFalse(self.status()["enabled"])

    def test_invalid_temperature_does_not_change_the_renderer(self):
        for args in (("--temperature", "0"), ("--temperature", "4000;exit"), ("--temperature",), ("--unknown",)):
            self.run_helper(*args, code=2)
        self.assertFalse(self.status()["enabled"])

    def test_two_concurrent_toggles_return_to_off(self):
        first = subprocess.Popen([str(self.helper)], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        second = subprocess.Popen([str(self.helper)], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        for process in (first, second):
            _, error = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, error)
        self.assertFalse(self.status()["enabled"])

    def test_shell_refresh_failure_does_not_undo_applied_tint(self):
        (self.bin / "omarchy-shell").write_text("#!/bin/sh\nexit 1\n")
        self.run_helper()
        self.assertTrue(self.status()["enabled"])


class NightlightInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.command = self.root / "usr/bin/omarchy-toggle-nightlight"
        self.service = self.root / "usr/share/omarchy/shell/plugins/services/nightlight/Service.qml"
        for path, fixture in ((self.command, "omarchy-toggle-nightlight"), (self.service, "nightlight-Service.qml")):
            path.parent.mkdir(parents=True)
            shutil.copy2(GUEST / "tests/fixtures" / fixture, path)
        self.command.chmod(0o755)

    def install(self, *args, code=0):
        result = subprocess.run(["python3", str(GUEST / "scripts/install-nightlight.py"),
                                 "--root", str(self.root), *args], capture_output=True, text=True)
        self.assertEqual(result.returncode, code, result.stderr)
        return result

    def test_preview_writes_no_installed_files(self):
        before = self.command.read_bytes()
        self.assertIn("Preview only", self.install().stdout)
        self.assertEqual(self.command.read_bytes(), before)
        self.assertFalse((self.root / "usr/local").exists())
        self.assertFalse((self.root / "var").exists())

    def test_install_is_idempotent_and_preserves_rollback_files(self):
        original = self.command.read_bytes()
        self.install("--apply")
        self.assertIn("omarchy-native-nightlight", self.command.read_text())
        self.assertIn('"--temperature"', self.service.read_text())
        backups = list((self.root / "var/lib/try-omarchy").glob("nightlight-backup.*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "usr/bin/omarchy-toggle-nightlight").read_bytes(), original)
        self.assertEqual(len(json.loads((backups[0] / "created-files.json").read_text())), 2)
        self.assertIn("already installed", self.install("--apply").stdout)
        self.assertEqual(len(list((self.root / "var/lib/try-omarchy").glob("nightlight-backup.*"))), 1)
        # Exercise the documented rollback using only this disposable root.
        for relative in json.loads((backups[0] / "created-files.json").read_text()):
            (self.root / relative).unlink()
        shutil.copytree(backups[0] / "usr", self.root / "usr", dirs_exist_ok=True)
        self.assertEqual(self.command.read_bytes(), original)
        self.install("--apply")

    def test_local_edits_are_refused_before_installing_any_assets(self):
        self.service.write_text(self.service.read_text() + "\n// local change\n")
        result = self.install("--apply", code=2)
        self.assertIn("local changes", result.stderr)
        self.assertFalse((self.root / "usr/local").exists())

    def test_existing_custom_asset_is_not_overwritten(self):
        asset = self.root / "usr/local/share/try-omarchy/nightlight.frag"
        asset.parent.mkdir(parents=True)
        asset.write_text("custom shader")
        self.install("--apply", code=2)
        self.assertEqual(asset.read_text(), "custom shader")
        self.assertNotIn("omarchy-native-nightlight", self.command.read_text())

    def test_write_failure_restores_already_changed_files(self):
        spec = importlib.util.spec_from_file_location("nightlight_installer", GUEST / "scripts/install-nightlight.py")
        installer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(installer)
        original_command, original_service = self.command.read_bytes(), self.service.read_bytes()
        replace = Path.replace

        def fail_asset(path, destination):
            if destination.name == "omarchy-native-nightlight":
                raise OSError("simulated full disk")
            return replace(path, destination)

        with patch("sys.argv", ["install-nightlight.py", "--root", str(self.root), "--apply"]):
            with patch.object(Path, "replace", fail_asset):
                with self.assertRaisesRegex(OSError, "full disk"):
                    installer.main()
        self.assertEqual(self.command.read_bytes(), original_command)
        self.assertEqual(self.service.read_bytes(), original_service)
        self.assertFalse((self.root / "usr/local/bin/omarchy-native-nightlight").exists())

    def test_symlink_target_is_refused(self):
        saved = self.root / "original-command"
        self.command.rename(saved)
        self.command.symlink_to(saved)
        self.install("--apply", code=2)
        self.assertFalse((self.root / "usr/local").exists())

    def test_only_the_exact_vm_token_selects_the_shader_backend(self):
        self.install("--apply")
        commands = self.root / "commands"
        commands.mkdir()
        log = self.root / "backend.log"
        bodies = {
            "cat": 'printf "%s\\n" "$NIGHTLIGHT_TEST_CMDLINE"',
            "omarchy-native-nightlight": 'printf "native:%s\\n" "$*" >>"$NIGHTLIGHT_TEST_LOG"',
            "pgrep": "exit 0",
            "omarchy-shell": "exit 0",
            "sleep": "exit 0",
            "hyprctl": 'printf "hyprsunset:%s\\n" "$*" >>"$NIGHTLIGHT_TEST_LOG"; echo 4000',
        }
        for name, body in bodies.items():
            path = commands / name
            path.write_text("#!/bin/sh\n" + body + "\n")
            path.chmod(0o755)
        for token, native in (("omarchy.qemu_virgl=1", True), ("omarchy.qemu_virgl=10", False),
                              ("xomarchy.qemu_virgl=1", False), ("quiet", False)):
            with self.subTest(token=token):
                log.unlink(missing_ok=True)
                environment = dict(os.environ, PATH=f"{commands}:{os.environ['PATH']}",
                                   NIGHTLIGHT_TEST_CMDLINE=f"root=/dev/vda {token} quiet",
                                   NIGHTLIGHT_TEST_LOG=str(log))
                subprocess.run([str(self.command), "--temperature", "4000"], env=environment,
                               check=True, capture_output=True)
                calls = log.read_text()
                self.assertEqual("native:" in calls, native)
                self.assertEqual("hyprsunset:" in calls, not native)


if __name__ == "__main__":
    unittest.main()
