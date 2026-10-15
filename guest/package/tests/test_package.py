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
        for directory in ("usr/bin", "usr/lib/try-omarchy", "usr/lib/try-omarchy/shims"):
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
        for name in ("systemctl", "ufw"):
            fake = tmp / name
            fake.write_text(f"#!/bin/sh\necho {name} \"$@\" >>{log}\n")
            fake.chmod(0o755)
        run(LIB / "ssh-access", env={"TRY_OMARCHY_HOST_CMDLINE": str(cmdline),
                                     "TRY_OMARCHY_SYSTEMCTL": str(tmp / "systemctl"), "TRY_OMARCHY_UFW": str(tmp / "ufw")})
        return [line for line in log.read_text().splitlines() if not line.startswith("ufw delete")] if log.exists() else []

    def test_starts_sshd_and_opens_the_firewall_only_when_forwarded(self):
        self.assertEqual(self.check("omarchy.qemu_virgl=1 tryomarchy.ssh_access=1"), [
            "ufw allow in proto tcp from 10.0.2.2 to any port 22 comment try-omarchy-ssh",
            "systemctl start --no-block sshd.service"])
        self.assertEqual(self.check("tryomarchy.ssh_access=1 tryomarchy.ssh_from=any")[0],
                         "ufw allow in proto tcp from any to any port 22 comment try-omarchy-ssh")
        self.assertEqual(self.check("omarchy.qemu_virgl=1"), [])
        self.assertEqual(self.check(""), [])


class UserSetup(unittest.TestCase):
    def test_places_loader_once(self):
        state = Path(tempfile.mkdtemp())
        env = {"XDG_STATE_HOME": str(state), "HOME": str(state), "TRY_OMARCHY_MENU_ENTRIES": "/usr/bin/true"}
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


class MenuEntries(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp())
        self.env = {"HOME": str(self.home), "XDG_CONFIG_HOME": "", "XDG_STATE_HOME": ""}
        self.menu = self.home / ".config/omarchy/extensions/omarchy-menu.jsonc"

    def entries(self):
        subprocess.run(["python3", str(LIB / "menu-entries")], env={**os.environ, **self.env}, check=True)

    @staticmethod
    def parse(text):
        # Omarchy's stripJsonc: whole-line comments and trailing commas.
        text = re.sub(r"^\s*//[^\n]*(\n|$)", "", text, flags=re.M)
        return json.loads(re.sub(r",(\s*[}\]])", r"\1", text))

    def test_adds_rows_to_the_seeded_template_once(self):
        self.menu.parent.mkdir(parents=True)
        self.menu.write_text('{\n  // Extend the menu.\n  // "personal": {"label":"Personal"},\n}\n')
        self.entries()
        parsed = self.parse(self.menu.read_text())
        self.assertEqual(set(parsed), {"setup.try-omarchy", "setup.security.touch-id",
                                       "setup.security.onepassword-touch-id"})
        self.assertEqual(parsed["setup.try-omarchy"]["icon"], "\ue900")
        self.assertEqual(parsed["setup.try-omarchy"]["iconFont"], "omarchy")
        self.menu.write_text("{}\n")  # the user removed them
        self.entries()
        self.assertEqual(self.menu.read_text(), "{}\n")

    def test_a_later_release_adds_only_its_new_rows(self):
        self.menu.parent.mkdir(parents=True)
        self.menu.write_text("{\n}\n")  # the user removed the first release's rows
        (self.home / ".local/state/try-omarchy").mkdir(parents=True)
        (self.home / ".local/state/try-omarchy/menu-entries-v1").touch()
        self.entries()
        self.assertEqual(set(self.parse(self.menu.read_text())), {"setup.security.onepassword-touch-id"})
        self.entries()
        self.assertEqual(len(self.parse(self.menu.read_text())), 1)

    def test_keeps_user_rows_and_creates_missing_file(self):
        self.menu.parent.mkdir(parents=True)
        self.menu.write_text('{\n  "personal": {"label":"Personal"}\n}\n')
        self.entries()
        self.assertIn("personal", self.parse(self.menu.read_text()))
        other = Path(tempfile.mkdtemp())
        subprocess.run(["python3", str(LIB / "menu-entries")], env={**os.environ, "HOME": str(other),
                       "XDG_CONFIG_HOME": "", "XDG_STATE_HOME": ""}, check=True)
        created = other / ".config/omarchy/extensions/omarchy-menu.jsonc"
        self.assertIn("setup.try-omarchy", self.parse(created.read_text()))


class Locale(unittest.TestCase):
    def seed(self, pending):
        tmp = Path(tempfile.mkdtemp())
        (tmp / "cmdline").write_text("tryomarchy.keyboard=jis tryomarchy.locale=ja_JP.UTF-8\n")
        (tmp / "locale.conf").write_text("LANG=en_US.UTF-8\nLC_TIME=en_GB.UTF-8\n")
        if pending:
            (tmp / "pending").touch()
        subprocess.run(["/bin/sh", str(FILES / "usr/bin/try-omarchy-locale")], check=True, env={**os.environ,
            "TRY_OMARCHY_LOCALE_CMDLINE_PATH": str(tmp / "cmdline"), "TRY_OMARCHY_LOCALE_CONF_PATH": str(tmp / "locale.conf"),
            "TRY_OMARCHY_LOCALE_PENDING_PATH": str(tmp / "pending"), "TRY_OMARCHY_LOCALE_SKIP_GENERATE": "1"})
        return (tmp / "locale.conf").read_text(), (tmp / "pending").exists()

    def test_seeds_only_while_owner_provisioning_is_pending(self):
        self.assertEqual(self.seed(True), ("LC_TIME=en_GB.UTF-8\nLANG=ja_JP.UTF-8\n", True))
        self.assertEqual(self.seed(False), ("LANG=en_US.UTF-8\nLC_TIME=en_GB.UTF-8\n", False))


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


def load(path, name):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class Recipe(unittest.TestCase):
    def test_battery_sources_and_backups_exist(self):
        recipe = (PACKAGE / "PKGBUILD").read_text()
        for name in ("dkms.conf", "Makefile", "try-omarchy-battery.c"):
            self.assertTrue((PACKAGE / "battery" / name).is_file(), name)
        for backup in re.findall(r"'(etc/[^']+)'", recipe):
            self.assertTrue((FILES / backup).is_file(), backup)
        self.assertNotIn("native-module", recipe)

    def test_build_copies_only_files_git_knows(self):
        build = (PACKAGE.parent / "build.sh").read_text()
        self.assertIn("git ls-files -z --cached --others --exclude-standard", build)
        self.assertNotIn("cp -r", build)

    def test_console_drop_in_keeps_the_screen_primary(self):
        text = (FILES / "etc/limine-entry-tool.d/50-try-omarchy-console.conf").read_text()
        line = next(line for line in text.splitlines() if line.startswith("KERNEL_CMDLINE[default]+="))
        consoles = re.findall(r"console=(\w+)", line)
        self.assertEqual(consoles, ["hvc0", "tty0"])

    def test_chromium_takes_input_methods(self):
        self.assertIn("--enable-wayland-ime", (FILES / "etc/chromium-flags.conf").read_text().split())


class InputInit(unittest.TestCase):
    STOCK = ("# Omarchy binds Super+I.\n[Hotkey/TriggerKeys]\n0=Zenkaku_Hankaku\n1=Hangul\n\n"
             "[Hotkey/ActivateKeys]\n0=Henkan\n\n[Hotkey/DeactivateKeys]\n0=Muhenkan\n\n"
             "[Behavior]\nActiveByDefault=False\n")

    def setUp(self):
        self.module = load(FILES / "usr/bin/try-omarchy-input-init", "input_init")
        self.tmp = Path(tempfile.mkdtemp())
        self.config = self.tmp / "fcitx5/config"
        self.marker = self.tmp / "state/try-omarchy/fcitx-jis-v1"
        self.stock = self.tmp / "stock"
        self.stock.write_text(self.STOCK)

    def init(self, cmdline="omarchy.qemu_virgl=1 tryomarchy.keyboard=jis"):
        return self.module.initialize(self.config, self.marker, cmdline, self.stock)

    def test_maps_kana_and_eisu_once(self):
        self.config.parent.mkdir()
        self.config.write_text(self.STOCK)
        self.assertTrue(self.init())
        sections = {name: self.module.section_values(self.config.read_text(), name)
                    for name in ("Hotkey/TriggerKeys", "Hotkey/ActivateKeys", "Hotkey/DeactivateKeys")}
        self.assertEqual(sections, {"Hotkey/TriggerKeys": ["Zenkaku_Hankaku"],
                                    "Hotkey/ActivateKeys": ["Henkan", "Hangul"],
                                    "Hotkey/DeactivateKeys": ["Muhenkan", "Hangul_Hanja"]})
        self.assertIn("ConsumeRedundantActivateKeys=True", self.config.read_text())
        self.assertIn("ActiveByDefault=False", self.config.read_text())
        self.config.write_text("edited\n")
        self.assertFalse(self.init())
        self.assertEqual(self.config.read_text(), "edited\n")

    def test_seeds_from_omarchy_when_missing_and_ignores_other_keyboards(self):
        self.assertFalse(self.init("tryomarchy.keyboard=ansi"))
        self.assertFalse(self.config.exists())
        self.assertTrue(self.init())
        self.assertIn("0=Henkan\n1=Hangul\n", self.config.read_text())


class TimeZone(unittest.TestCase):
    def setUp(self):
        self.module = load(FILES / "usr/bin/try-omarchy-timezone", "timezone")
        self.tmp = Path(tempfile.mkdtemp())
        self.zoneinfo = self.tmp / "zoneinfo"
        for zone in ("Asia/Tokyo", "Europe/Lisbon", "UTC"):
            (self.zoneinfo / zone).parent.mkdir(parents=True, exist_ok=True)
            (self.zoneinfo / zone).write_text(zone)
        self.localtime = self.tmp / "localtime"
        self.state = self.tmp / "timezone.json"

    def link(self, zone):
        self.localtime.unlink(missing_ok=True)
        self.localtime.symlink_to(self.zoneinfo / zone)

    def sync(self, zone, preserve=True):
        return self.module.synchronize(zone, state_path=self.state, localtime=self.localtime,
                                       zoneinfo=self.zoneinfo, apply=lambda target: self.link(
                                           target.relative_to(self.zoneinfo).as_posix()),
                                       preserve_existing=preserve)

    def mode(self):
        return json.loads(self.state.read_text())["mode"]

    def test_keeping_the_mac_zone_in_setup_follows_the_mac(self):
        self.link("Asia/Tokyo")  # the setup form's default, from the tzupdate shim
        self.assertFalse(self.sync("Asia/Tokyo"))
        self.assertEqual(self.mode(), "auto")
        self.assertTrue(self.sync("Europe/Lisbon"))  # the Mac moved
        self.assertEqual(self.localtime.resolve(), (self.zoneinfo / "Europe/Lisbon").resolve())

    def test_another_zone_in_setup_is_manual(self):
        self.link("UTC")
        self.sync("Asia/Tokyo")
        self.assertEqual(self.mode(), "manual")
        self.assertFalse(self.sync("Europe/Lisbon"))
        self.assertEqual(self.localtime.resolve(), (self.zoneinfo / "UTC").resolve())

    def test_relinking_the_same_zone_keeps_following(self):
        self.link("Asia/Tokyo")
        self.sync("Asia/Tokyo")
        self.link("Asia/Tokyo")  # a new inode, same zone
        self.sync("Asia/Tokyo")
        self.assertEqual(self.mode(), "auto")
        self.link("UTC")  # chosen in Omarchy's time zone menu
        self.assertFalse(self.sync("Europe/Lisbon"))
        self.assertEqual(self.mode(), "manual")


class TzupdateShim(unittest.TestCase):
    def run_shim(self, state=None, cmdline="tryomarchy.timezone=Asia/Tokyo"):
        tmp = Path(tempfile.mkdtemp())
        (tmp / "cmdline").write_text(cmdline + "\n")
        if state is not None:
            (tmp / "state").write_text(json.dumps(state))
        real = tmp / "tzupdate"
        real.write_text("#!/bin/sh\necho real \"$@\"\n")
        real.chmod(0o755)
        return subprocess.run([str(LIB / "shims/tzupdate"), "-p"], capture_output=True, text=True, check=True,
                              env={**os.environ, "TRY_OMARCHY_TIMEZONE_STATE": str(tmp / "state"),
                                   "TRY_OMARCHY_HOST_CMDLINE": str(tmp / "cmdline"),
                                   "TRY_OMARCHY_TZUPDATE": str(real)}).stdout.strip()

    def test_offers_the_mac_zone_until_the_guest_chooses(self):
        self.assertEqual(self.run_shim(), "Asia/Tokyo")
        self.assertEqual(self.run_shim({"mode": "auto", "zone": "Europe/Lisbon", "fingerprint": []}), "Europe/Lisbon")
        self.assertEqual(self.run_shim({"mode": "manual"}), "real -p")
        self.assertEqual(self.run_shim(cmdline="omarchy.qemu_virgl=1"), "real -p")

    def test_only_owner_setup_sees_it(self):
        drop_in = (FILES / "usr/lib/systemd/system/omarchy-provision-owner.service.d"
                   / "10-try-omarchy-native.conf").read_text()
        self.assertIn("Environment=PATH=/usr/lib/try-omarchy/shims:", drop_in)


class Hyprland(unittest.TestCase):
    def test_cursor_is_hidden_again_after_the_screensaver(self):
        profile = (FILES / "usr/share/try-omarchy/hyprland.lua").read_text()
        handler = profile[profile.index('hl.on("window.destroy"'):]
        self.assertIn("invisible = true", handler[:200])


class OnePassword(unittest.TestCase):
    def test_enables_the_shipped_unit(self):
        command = (FILES / "usr/bin/try-omarchy-onepassword-touch-id").read_text()
        self.assertIn('unit="try-omarchy-onepassword-touch-id@$user.service"', command)
        self.assertTrue((FILES / "usr/lib/systemd/system/try-omarchy-onepassword-touch-id@.service").is_file())
        self.assertIn("sudo systemctl enable --now", command)


if __name__ == "__main__":
    unittest.main()
