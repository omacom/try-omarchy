#!/usr/bin/env python3
"""Contract tests for the try-omarchy guest package (guest/package)."""

import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
import unittest

PACKAGE = Path(__file__).resolve().parents[1] / "try-omarchy"
FILES = PACKAGE / "files"
LIB = FILES / "usr/lib/try-omarchy"


def run(script, *args, env=None, check=True):
    return subprocess.run(["/bin/bash", str(script), *args], env={**os.environ, **(env or {})},
                          capture_output=True, text=True, check=check)


class PackageLayout(unittest.TestCase):
    def test_nothing_under_usr_local_and_no_kernel_command_line(self):
        for path in FILES.rglob("*"):
            relative = path.relative_to(FILES).as_posix()
            self.assertFalse(relative.startswith("usr/local"), relative)
            if path.is_file():
                text = path.read_text(errors="ignore")
                self.assertNotIn("/usr/local/", text, relative)
                self.assertNotIn("/proc/cmdline", text, relative)

    def test_only_owned_paths(self):
        # The package never ships into Omarchy's trees or the user skeleton,
        # which omarchy and omarchy-settings own.
        for path in FILES.rglob("*"):
            relative = path.relative_to(FILES).as_posix()
            for forbidden in ("usr/share/omarchy/", "etc/skel/", "usr/share/omarchy-platform/"):
                self.assertFalse(relative.startswith(forbidden), relative)

    def test_executables(self):
        for directory in ("usr/bin", "usr/lib/try-omarchy"):
            for path in (FILES / directory).iterdir():
                if path.suffix in ("", ".py") and path.is_file():
                    self.assertTrue(path.stat().st_mode & stat.S_IXUSR, path)

    def test_presets_name_shipped_units(self):
        for preset, unit_dir in (("system-preset/80-try-omarchy.preset", "system"),
                                 ("user-preset/80-try-omarchy.preset", "user")):
            for line in (FILES / "usr/lib/systemd" / preset).read_text().splitlines():
                verb, unit = line.split()
                self.assertEqual(verb, "enable")
                self.assertTrue((FILES / "usr/lib/systemd" / unit_dir / unit).is_file(), unit)

    def test_install_script_lists_every_preset_unit(self):
        install = (PACKAGE / "try-omarchy.install").read_text()
        for preset in ("system-preset", "user-preset"):
            for line in (FILES / "usr/lib/systemd" / preset / "80-try-omarchy.preset").read_text().splitlines():
                self.assertIn(line.split()[1], install)

    def test_units_reference_existing_programs(self):
        for unit in (FILES / "usr/lib/systemd").rglob("*"):
            if not unit.is_file():
                continue
            for match in re.finditer(r"^Exec\w*=-?(/\S+)", unit.read_text(), re.M):
                program = match.group(1)
                if program.startswith(("/usr/bin/rm", "/usr/bin/python3")):
                    continue
                self.assertTrue((FILES / program.lstrip("/")).is_file(), f"{unit.name}: {program}")


class HostConfig(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.credentials = self.tmp / "credentials"
        self.credentials.mkdir()
        self.output = self.tmp / "run/try-omarchy/cmdline"
        self.env = {"CREDENTIALS_DIRECTORY": str(self.credentials), "TRY_OMARCHY_HOST_CONFIG_OUTPUT": str(self.output)}

    def test_publishes_tokens(self):
        (self.credentials / "tryomarchy.host").write_text("omarchy.qemu_virgl=1 tryomarchy.keyboard=jis\n")
        run(LIB / "host-config", env=self.env)
        self.assertEqual(self.output.read_text(), "omarchy.qemu_virgl=1 tryomarchy.keyboard=jis\n")
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o644)

    def test_without_credential_writes_nothing(self):
        run(LIB / "host-config", env=self.env)
        self.assertFalse(self.output.exists())

    def test_rejects_control_characters_and_oversize(self):
        (self.credentials / "tryomarchy.host").write_bytes(b"a\x1bb")
        self.assertNotEqual(run(LIB / "host-config", env=self.env, check=False).returncode, 0)
        (self.credentials / "tryomarchy.host").write_text("x" * 20000)
        self.assertNotEqual(run(LIB / "host-config", env=self.env, check=False).returncode, 0)
        self.assertFalse(self.output.exists())


class SshAccess(unittest.TestCase):
    def check(self, options):
        tmp = Path(tempfile.mkdtemp())
        cmdline = tmp / "cmdline"
        cmdline.write_text(options + "\n")
        log = tmp / "log"
        fake = tmp / "systemctl"
        fake.write_text(f"#!/bin/sh\necho \"$@\" >>{log}\n")
        fake.chmod(0o755)
        run(LIB / "ssh-access", env={"TRY_OMARCHY_HOST_CMDLINE": str(cmdline), "TRY_OMARCHY_SYSTEMCTL": str(fake)})
        return log.read_text() if log.exists() else ""

    def test_starts_sshd_only_when_forwarded(self):
        self.assertEqual(self.check("omarchy.qemu_virgl=1 tryomarchy.ssh_access=1"), "start --no-block sshd.service\n")
        self.assertEqual(self.check("omarchy.qemu_virgl=1"), "")
        self.assertEqual(self.check(""), "")


class UserSetup(unittest.TestCase):
    def test_places_loader_once(self):
        state = Path(tempfile.mkdtemp())
        env = {"XDG_STATE_HOME": str(state), "HOME": str(state)}
        run(LIB / "user-setup", env=env)
        loader = state / "omarchy/toggles/hypr/zz-try-omarchy.lua"
        first = loader.read_text()
        self.assertIn('dofile, "/usr/share/try-omarchy/hyprland.lua"', first)
        before = loader.stat().st_mtime_ns
        run(LIB / "user-setup", env=env)
        self.assertEqual(loader.stat().st_mtime_ns, before)
        loader.write_text("-- edited\n")
        run(LIB / "user-setup", env=env)
        self.assertEqual(loader.read_text(), first)


class GuestStatus(unittest.TestCase):
    def load(self):
        loader = importlib.machinery.SourceFileLoader("guest_status", str(LIB / "guest-status"))
        spec = importlib.util.spec_from_loader("guest_status", loader)
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
        return module

    def test_report_shape(self):
        module = self.load()
        versions = {"try-omarchy": "0.1.0-1", "omarchy-dev": "4.0.0.r1-1", "linux-omarchy": "7.2.8-11"}
        module.package_version = versions.get
        module.channel = lambda: "edge"
        module.INSTALL_STATE = Path("/nonexistent")
        report = json.loads(module.report())
        self.assertEqual(report["protocol"], 1)
        self.assertEqual(report["package"], "0.1.0-1")
        self.assertEqual(report["omarchy"], "4.0.0.r1-1")
        self.assertEqual(report["channel"], "edge")
        self.assertEqual(report["kernel"]["installed"], "7.2.8-11")
        self.assertLess(len(module.report()), 4096)


class PackageInstall(unittest.TestCase):
    def test_name_pattern_matches_launcher(self):
        install = (LIB / "package-install").read_text()
        launcher = (Path(__file__).resolve().parents[3] / "macos/run-shell-guest.sh").read_text()
        pattern = r"try-omarchy-[0-9][A-Za-z0-9._+-]*-(aarch64|any)\.pkg\.tar\.zst"
        self.assertIn(pattern, install.replace("^", "").replace("$", ""))
        self.assertIn(pattern, launcher.replace("^", "").replace("$", ""))
        for name, ok in (("try-omarchy-0.1.0-1-aarch64.pkg.tar.zst", True),
                         ("try-omarchy-0.1.0-1-aarch64.pkg.tar.zst/../x", False),
                         ("other-0.1-1-aarch64.pkg.tar.zst", False)):
            self.assertEqual(bool(re.fullmatch(pattern, name)), ok, name)


if __name__ == "__main__":
    unittest.main()
