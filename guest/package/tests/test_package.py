#!/usr/bin/env python3
"""Contract tests for the try-omarchy guest package (guest/package)."""

import configparser
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
                # Only the XDG default search path, kept when prepending to it.
                text = text.replace("${XDG_DATA_DIRS:-/usr/local/share:/usr/share}", "")
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
        for directory in ("usr/bin", "usr/lib/try-omarchy", "usr/lib/try-omarchy/shims", "usr/lib/try-omarchy/bin"):
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
                # Other packages' programs: coreutils, python, rtkit (a drop-in).
                if program.startswith(("/usr/bin/rm", "/usr/bin/python3", "/usr/lib/rtkit-daemon")):
                    continue
                self.assertTrue((FILES / program.lstrip("/")).is_file(), f"{unit.name}: {program}")


class GraphicalBridges(unittest.TestCase):
    def test_desktop_bridges_start_and_stop_with_the_graphical_session(self):
        for bridge in ("audio", "camera", "clipboard"):
            unit = configparser.ConfigParser(interpolation=None, strict=False)
            unit.read(FILES / f"usr/lib/systemd/user/omarchy-native-{bridge}-bridge.service")
            self.assertIn("graphical-session.target", unit["Unit"]["PartOf"].split())
            self.assertIn("graphical-session.target", unit["Unit"]["After"].split())
            self.assertEqual(unit["Install"]["WantedBy"], "graphical-session.target")

    def test_upgrade_moves_enabled_bridges_and_keeps_disabled_or_masked_choices(self):
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            log = tmp / "calls"
            systemctl = tmp / "systemctl"
            systemctl.write_text('''#!/bin/bash
printf '%s\\n' "$*" >>"$TEST_LOG"
if [[ $1 == --global && $2 == is-enabled ]]; then
  case $3 in
    *audio*) echo "$AUDIO_STATE" ;;
    *camera*) echo "$CAMERA_STATE" ;;
  esac
fi
''')
            systemctl.chmod(0o755)
            # pacman's vercmp, for release numbers like 0.1.0-13.
            vercmp = tmp / "vercmp"
            vercmp.write_text('#!/usr/bin/python3\nimport re, sys\n'
                              'a, b = (tuple(map(int, re.split(r"[.-]", v))) for v in sys.argv[1:3])\n'
                              'print((a > b) - (a < b))\n')
            vercmp.chmod(0o755)
            for audio, camera, old in (("enabled", "disabled", "0.1.0-12"), ("masked", "enabled", "0.1.0-13")):
                log.write_text("")
                # pacman passes the new and the old version.
                result = subprocess.run(["/bin/bash", "-c", 'source "$1"; post_upgrade 0.1.0-20 "$2"', "bash",
                                         str(PACKAGE / "try-omarchy.install"), old], check=True,
                                        capture_output=True, text=True, env={
                    **os.environ, "PATH": f"{tmp}:{os.environ['PATH']}", "TEST_LOG": str(log),
                    "AUDIO_STATE": audio, "CAMERA_STATE": camera,
                })
                self.assertEqual(result.stderr, "")
                # NTP is enabled once, on the upgrade that brings it.
                ntp = [line for line in log.read_text().splitlines() if "timesyncd" in line]
                self.assertEqual(ntp, ["enable --now systemd-timesyncd.service"] if old == "0.1.0-12" else [])
                migrated = [line for line in log.read_text().splitlines() if "reenable" in line]
                expected = [f"--global reenable omarchy-native-{bridge}-bridge.service"
                            for bridge, state in (("audio", audio), ("camera", camera))
                            if state == "enabled"]
                self.assertEqual(migrated, expected)


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
    def test_offers_the_project_wallpaper_once_without_changing_the_background(self):
        home = Path(tempfile.mkdtemp())
        shipped = FILES / "usr/share/try-omarchy/backgrounds"
        env = {"HOME": str(home), "XDG_STATE_HOME": "", "XDG_CONFIG_HOME": "", "TRY_OMARCHY_MENU_ENTRIES": "/usr/bin/true",
               "TRY_OMARCHY_IDLE_DEFAULTS": "/usr/bin/true", "TRY_OMARCHY_BACKGROUNDS": str(shipped)}
        run(LIB / "user-setup", env=env)
        link = home / ".config/omarchy/backgrounds/tokyo-night/try-omarchy-wallpaper.jpg"
        self.assertTrue(link.is_symlink())
        self.assertEqual(Path(os.readlink(link)), shipped / "tokyo-night/try-omarchy-wallpaper.jpg")
        # Only an extra choice: Omarchy's current background is left alone.
        self.assertFalse((home / ".local/state/omarchy/current").exists())
        link.unlink()  # the user removed it
        run(LIB / "user-setup", env=env)
        self.assertFalse(link.exists() or link.is_symlink())

    def test_wallpaper_is_shipped_for_tokyo_night(self):
        image = FILES / "usr/share/try-omarchy/backgrounds/tokyo-night/try-omarchy-wallpaper.jpg"
        self.assertEqual(image.read_bytes()[:3], b"\xff\xd8\xff")
        self.assertEqual(stat.S_IMODE(image.stat().st_mode), 0o644)

    def test_places_loader_once(self):
        state = Path(tempfile.mkdtemp())
        env = {"XDG_STATE_HOME": str(state), "HOME": str(state), "TRY_OMARCHY_MENU_ENTRIES": "/usr/bin/true",
               "TRY_OMARCHY_IDLE_DEFAULTS": "/usr/bin/true", "TRY_OMARCHY_BACKGROUNDS": str(state / "none")}
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
    # Omarchy's own rows as quattro 51bfd1d ships them.
    OMARCHY = """{
  // Omarchy's menu
  "update.timezone": {"icon":"","label":"Timezone","action":"omarchy-menu-timezone"},
  "setup.direct-boot": {"icon":"","label":"Direct Boot","when":"! omarchy-hw-aarch64-apple && [[ ! -f /etc/limine-entry-tool.d/zz-omarchy-dgx-spark.conf ]]","action":"omarchy-launch-floating-terminal-with-presentation omarchy-setup-direct-boot"},
  "update.firmware": {"icon":"","label":"Firmware","action":"omarchy-launch-floating-terminal-with-presentation omarchy-update-firmware"},
  "update.hardware.wifi": {"icon":"\U000f16be","label":"Wi-Fi","action":"omarchy-launch-floating-terminal-with-presentation omarchy-restart-wifi"},
  "update.hardware.bluetooth": {"icon":"\U000f00af","label":"Bluetooth","action":"omarchy-launch-floating-terminal-with-presentation omarchy-restart-bluetooth"},
  "trigger.appearance.top-bar.indicators.battery-percentage": {"icon":"\U000f0079","label":"Battery Percentage","when":"omarchy-hw-laptop","action":"omarchy-shell omarchy.power togglePercentage"},
  "install.gaming.geforce-now": {"icon":"\U000f08b9","label":"NVIDIA GeForce NOW","disabled":"flatpak info com.nvidia.geforcenow","action":"omarchy-launch-floating-terminal-with-presentation omarchy-install-gaming-geforce-now"},
  "install.gaming.battlenet": {"icon":"","label":"Battle.net","disabled":"[[ -d $HOME/Games/battlenet ]]","action":"omarchy-launch-floating-terminal-with-presentation omarchy-install-gaming-battlenet"},
  "install.gaming.lutris": {"icon":"","label":"Lutris","disabled":"omarchy-pkg-present lutris","action":"omarchy-launch-floating-terminal-with-presentation omarchy-install-gaming-lutris"},
}
"""
    OWN = {"setup.try-omarchy", "setup.security.touch-id", "setup.security.onepassword-touch-id",
           "setup.import-previous-vm"}
    CHANGED = {"update.timezone", "setup.direct-boot", "update.firmware", "update.hardware.wifi",
               "update.hardware.bluetooth", "trigger.appearance.top-bar.indicators.battery-percentage",
               "install.gaming.geforce-now", "install.gaming.battlenet", "install.gaming.lutris"}

    def setUp(self):
        self.home = Path(tempfile.mkdtemp())
        self.omarchy = self.home / "omarchy-menu.jsonc"
        self.omarchy.write_text(self.OMARCHY)
        self.env = {"HOME": str(self.home), "XDG_CONFIG_HOME": "", "XDG_STATE_HOME": "",
                    "TRY_OMARCHY_OMARCHY_MENU": str(self.omarchy)}
        self.menu = self.home / ".config/omarchy/extensions/omarchy-menu.jsonc"
        self.state = self.home / ".local/state/try-omarchy"

    def entries(self):
        subprocess.run(["python3", str(LIB / "menu-entries")], env={**os.environ, **self.env}, check=True)

    @staticmethod
    def parse(text):
        # Omarchy's stripJsonc: whole-line comments and trailing commas.
        text = re.sub(r"^\s*//[^\n]*(\n|$)", "", text, flags=re.M)
        return json.loads(re.sub(r",(\s*[}\]])", r"\1", text))

    def test_changed_rows_carry_omarchys_whole_row(self):
        # Omarchy's merge fills every field an extension row leaves out with a
        # default (the label becomes the id, the action empty).
        self.menu.parent.mkdir(parents=True)
        self.menu.write_text('{\n  // Extend the menu.\n  // "personal": {"label":"Personal"},\n}\n')
        self.entries()
        parsed = self.parse(self.menu.read_text())
        omarchy = self.parse(self.OMARCHY)
        self.assertEqual(set(parsed), self.OWN | self.CHANGED)
        self.assertEqual(parsed["setup.try-omarchy"]["icon"], "")
        for key in self.CHANGED:
            for field in ("icon", "label", "action"):
                if field != "action" or key != "update.timezone":
                    self.assertEqual(parsed[key][field], omarchy[key][field], (key, field))
        self.assertIn("/usr/bin/try-omarchy-timezone-menu", parsed["update.timezone"]["action"])
        self.assertEqual(parsed["setup.direct-boot"]["when"],
                         "! omarchy-hw-vm && (! omarchy-hw-aarch64-apple && "
                         "[[ ! -f /etc/limine-entry-tool.d/zz-omarchy-dgx-spark.conf ]])")
        self.assertEqual(parsed["update.firmware"]["when"], "! omarchy-hw-vm")
        self.assertEqual(parsed["install.gaming.lutris"]["when"], "omarchy-hw-x86")
        self.assertEqual(parsed["install.gaming.lutris"]["disabled"], "omarchy-pkg-present lutris")
        self.assertEqual(parsed["trigger.appearance.top-bar.indicators.battery-percentage"]["when"],
                         "(omarchy-hw-laptop) || compgen -G '/sys/class/power_supply/BAT*' >/dev/null")
        # Removed rows stay removed.
        self.menu.write_text("{}\n")
        self.entries()
        self.assertEqual(self.menu.read_text(), "{}\n")

    def test_rows_follow_omarchy_until_the_user_edits_them(self):
        self.entries()
        self.omarchy.write_text(self.OMARCHY.replace('"label":"Firmware"', '"label":"Device Firmware"')
                                .replace('"label":"Lutris"', '"label":"Lutris Games"'))
        text = self.menu.read_text()
        self.menu.write_text(text.replace('"label":"Lutris"', '"label":"My Lutris"'))
        self.entries()
        parsed = self.parse(self.menu.read_text())
        self.assertEqual(parsed["update.firmware"]["label"], "Device Firmware")
        self.assertEqual(parsed["install.gaming.lutris"]["label"], "My Lutris")

    def test_repairs_rows_earlier_packages_wrote(self):
        self.menu.parent.mkdir(parents=True)
        self.menu.write_text('{\n  "update.firmware": {"when":"! omarchy-hw-vm"},\n'
                             '  "update.hardware.wifi": {"when":"! omarchy-hw-vm","label":"Mine"},\n}\n')
        self.state.mkdir(parents=True)
        (self.state / "menu-entries").write_text("5\n")
        self.entries()
        parsed = self.parse(self.menu.read_text())
        self.assertEqual(parsed["update.firmware"]["label"], "Firmware")
        self.assertEqual(parsed["update.hardware.wifi"], {"when": "! omarchy-hw-vm", "label": "Mine"})
        # Nothing re-added; only the newest release's row is new.
        self.assertEqual(set(parsed), {"update.firmware", "update.hardware.wifi", "setup.import-previous-vm"})

    def test_without_omarchys_menu_only_own_rows_are_added(self):
        self.omarchy.unlink()
        self.entries()
        self.assertEqual(set(self.parse(self.menu.read_text())), self.OWN)

    def test_a_later_release_adds_only_its_new_rows(self):
        self.menu.parent.mkdir(parents=True)
        self.menu.write_text("{\n}\n")  # the user removed the first release's rows
        self.state.mkdir(parents=True)
        (self.state / "menu-entries-v1").touch()
        self.entries()
        self.assertEqual(set(self.parse(self.menu.read_text())),
                         {"setup.security.onepassword-touch-id", "setup.import-previous-vm"} | self.CHANGED)
        self.entries()
        self.assertEqual(len(self.parse(self.menu.read_text())), 2 + len(self.CHANGED))
        self.assertEqual(self.menu.read_text().count("// Try Omarchy:"), 1)

    def test_an_existing_header_is_not_repeated(self):
        self.menu.parent.mkdir(parents=True)
        self.menu.write_text("{\n  // Try Omarchy: Mac app settings and Touch ID (added once each; safe to remove).\n}\n")
        self.state.mkdir(parents=True)
        (self.state / "menu-entries").write_text("2\n")
        self.entries()
        text = self.menu.read_text()
        self.assertEqual(set(self.parse(text)), {"setup.import-previous-vm"} | self.CHANGED)
        self.assertEqual(text.count("// Try Omarchy:"), 1)

    def test_keeps_user_rows_and_creates_missing_file(self):
        self.menu.parent.mkdir(parents=True)
        self.menu.write_text('{\n  "personal": {"label":"Personal"}\n}\n')
        self.entries()
        self.assertIn("personal", self.parse(self.menu.read_text()))
        other = Path(tempfile.mkdtemp())
        subprocess.run(["python3", str(LIB / "menu-entries")], env={**os.environ, **self.env, "HOME": str(other)},
                       check=True)
        created = other / ".config/omarchy/extensions/omarchy-menu.jsonc"
        self.assertIn("setup.try-omarchy", self.parse(created.read_text()))


class IdleDefaults(unittest.TestCase):
    STOCK = '{\n  "idle": {\n    "screensaver": 150,\n    "lock": 300\n  },\n  "bar": {\n    "position": "top"\n  }\n}\n'

    def setUp(self):
        self.home = Path(tempfile.mkdtemp())
        self.shell = self.home / ".config/omarchy/shell.json"
        self.marker = self.home / ".local/state/try-omarchy/idle-defaults"

    def run_once(self):
        subprocess.run(["python3", str(LIB / "idle-defaults")], check=True,
                       env={**os.environ, "HOME": str(self.home), "XDG_CONFIG_HOME": "", "XDG_STATE_HOME": ""})

    def write(self, text):
        self.shell.parent.mkdir(parents=True, exist_ok=True)
        self.shell.write_text(text)

    def test_stock_timeouts_are_turned_off_once_and_nothing_else_changes(self):
        self.write(self.STOCK)
        self.run_once()
        self.assertEqual(self.shell.read_text(), self.STOCK.replace("150", "0").replace("300", "0"))
        self.assertTrue(self.marker.exists())
        self.write(self.STOCK)  # the user turned them back on
        self.run_once()
        self.assertEqual(self.shell.read_text(), self.STOCK)

    def test_a_users_own_timeouts_stay(self):
        custom = self.STOCK.replace("150", "600")
        self.write(custom)
        self.run_once()
        self.assertEqual(self.shell.read_text(), custom)
        self.assertTrue(self.marker.exists())

    def test_waits_for_omarchy_and_leaves_other_files_alone(self):
        self.run_once()
        self.assertFalse(self.marker.exists())  # retried at the next login
        self.write("{ not json")
        self.run_once()
        self.assertEqual(self.shell.read_text(), "{ not json")
        self.assertFalse(self.marker.exists())


class Rtkit(unittest.TestCase):
    def test_mac_sleep_does_not_demote_pipewire(self):
        drop_in = (FILES / "usr/lib/systemd/system/rtkit-daemon.service.d"
                   / "10-try-omarchy-no-canary.conf").read_text()
        self.assertIn("[Service]\nExecStart=\nExecStart=/usr/lib/rtkit-daemon --no-canary\n", drop_in)


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
    def test_waits_for_omarchys_first_boot_hardware_setup(self):
        # Both run pacman at first boot; a second transaction fails on the lock.
        unit = (FILES / "usr/lib/systemd/system/try-omarchy-package-install.service").read_text()
        after = re.search(r"^After=(.*)$", unit, re.M).group(1).split()
        self.assertIn("omarchy-provision-hardware.service", after)
        self.assertRegex(unit, r"(?m)^Before=.*omarchy-provision-owner\.service")

    def test_name_pattern_matches_launcher(self):
        install = (LIB / "package-install").read_text()
        launcher = (Path(__file__).resolve().parents[3] / "macos/run-qemu-gpu.sh").read_text()
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


class Power(unittest.TestCase):
    def test_sleep_uses_omarchys_own_off_switch(self):
        # bin/omarchy-sleep-disabled tests for exactly this file; the System
        # menu then hides Suspend and Hibernate.
        conf = FILES / "etc/systemd/sleep.conf.d/omarchy-sleep-disabled.conf"
        parser = configparser.ConfigParser()
        parser.optionxform = str
        parser.read(conf)
        self.assertEqual(dict(parser["Sleep"]), {"AllowSuspend": "no", "AllowHibernation": "no",
                                                 "AllowSuspendThenHibernate": "no", "AllowHybridSleep": "no"})
        self.assertIn("'etc/systemd/sleep.conf.d/omarchy-sleep-disabled.conf'", (PACKAGE / "PKGBUILD").read_text())

    def test_ntp_is_enabled_on_install_and_once_on_upgrade(self):
        install = (PACKAGE / "try-omarchy.install").read_text()
        self.assertIn("systemctl enable --now systemd-timesyncd.service", install)
        post_install = install[install.index("post_install()"):install.index("post_upgrade()")]
        post_upgrade = install[install.index("post_upgrade()"):]
        self.assertIn("_enable_ntp", post_install)
        self.assertIn('if [ "$(vercmp "$2" 0.1.0-13)" -lt 0 ]; then\n    _enable_ntp', post_upgrade)


class ScreenRecording(unittest.TestCase):
    def test_wf_recorder_is_the_fallback_for_virgl(self):
        # gpu-screen-recorder refuses VirGL; Omarchy falls back to wf-recorder.
        recipe = (PACKAGE / "PKGBUILD").read_text()
        self.assertIn("'wf-recorder: screen recording", recipe)
        factory = (PACKAGE.parent.parent / "factory/build-image.sh").read_text()
        self.assertIn("bsdtar -xOf \"$package\" .PKGINFO | sed -n 's/^optdepend = ", factory)
        self.assertIn('target_install "${optional[@]}"', factory)


class Dependencies(unittest.TestCase):
    def test_upgrades_inside_a_vm_need_no_new_downloads(self):
        # The app upgrades this package at boot, possibly offline or with a
        # stale database. Every hard dependency is in the factory image
        # already; new needs go to optdepends, which the factory installs.
        recipe = (PACKAGE / "PKGBUILD").read_text()
        block = recipe[recipe.index("depends=(\n"):]
        names = re.findall(r"'([^']+)'", block[:block.index(")")])
        self.assertEqual(names, ["bash", "dkms", "fcitx5-chewing", "fcitx5-hangul", "fcitx5-mozc", "gtk3",
                                 "linux-omarchy-headers", "noto-fonts-cjk", "openssl", "polkit", "python",
                                 "python-gobject", "systemd", "v4l2loopback-dkms"])


class PowerKey(unittest.TestCase):
    def test_app_shutdown_powers_off_after_omarchys_ignore_default(self):
        dropin = FILES / "usr/lib/systemd/logind.conf.d/90-try-omarchy-power-key.conf"
        self.assertIn("HandlePowerKey=poweroff", dropin.read_text())
        # Omarchy's 10-ignore-power-button.conf sorts first, so this one wins.
        self.assertGreater(dropin.name, "10-ignore-power-button.conf")
        self.assertIn("systemctl kill -s HUP systemd-logind.service", (PACKAGE / "try-omarchy.install").read_text())


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

    def test_mode_is_readable_by_the_desktop_picker(self):
        self.link("Asia/Tokyo")
        self.sync("Asia/Tokyo")
        self.assertEqual(stat.S_IMODE(self.state.stat().st_mode), 0o644)
        self.assertEqual(self.module.current_mode(self.state), "follow")
        self.link("UTC")
        self.sync("Asia/Tokyo")
        self.assertEqual(self.module.current_mode(self.state), "fixed")
        self.assertEqual(self.module.current_mode(self.tmp / "missing.json"), "follow")

    def test_mac_zone_comes_from_the_launch_until_the_agent_runs(self):
        cmdline = self.tmp / "cmdline"
        cmdline.write_text("omarchy.qemu_virgl=1 tryomarchy.timezone=Asia/Tokyo\n")
        host = self.tmp / "host-timezone"
        self.assertEqual(self.module.mac_zone(host, cmdline), "Asia/Tokyo")
        self.assertEqual(self.module.mirror_label(host, self.zoneinfo, cmdline), "Same as macOS")
        host.write_text("Europe/Lisbon\n")
        self.assertEqual(self.module.mac_zone(host, cmdline), "Europe/Lisbon")

    def test_relinking_the_same_zone_keeps_following(self):
        self.link("Asia/Tokyo")
        self.sync("Asia/Tokyo")
        self.link("Asia/Tokyo")  # a new inode, same zone
        self.sync("Asia/Tokyo")
        self.assertEqual(self.mode(), "auto")
        self.link("UTC")  # chosen in Omarchy's time zone menu
        self.assertFalse(self.sync("Europe/Lisbon"))
        self.assertEqual(self.mode(), "manual")


class TimeZoneMenu(unittest.TestCase):
    def pick(self, choice, mode="follow", mac="Same as macOS"):
        tmp = Path(tempfile.mkdtemp())
        log = tmp / "log"
        stubs = {
            "try-omarchy-timezone": f'case $1 in --mirror-label) [ -n "{mac}" ] && echo "{mac}" || exit 1;;'
                                    f' --mode) echo {mode};; esac',
            "timedatectl": 'case $1 in list-timezones) printf "Asia/Tokyo\\nUTC\\n";; show) echo Asia/Tokyo;; esac',
            "omarchy-menu-select": f'cat > "{tmp}/options"; echo "$@" > "{tmp}/args"; echo "{choice}"',
            "omarchy-i18n": 'echo "$@"',
            "sudo": f'echo sudo "$@" >> "{log}"',
            "omarchy-shell": f'echo shell "$@" >> "{log}"',
            "omarchy-notification-send": f'echo notify "$@" >> "{log}"',
        }
        for name, body in stubs.items():
            (tmp / name).write_text(f"#!/bin/sh\n{body}\n")
            (tmp / name).chmod(0o755)
        subprocess.run(["/bin/bash", str(FILES / "usr/bin/try-omarchy-timezone-menu")], check=True,
                       env={**os.environ, "PATH": f"{tmp}:/usr/bin:/bin"})
        return (tmp / "options").read_text().splitlines(), (tmp / "args").read_text(), log.read_text()

    def test_same_as_macos_comes_first_and_follows_the_mac(self):
        options, args, log = self.pick("Same as macOS")
        self.assertEqual(options, ["Same as macOS", "Asia/Tokyo", "UTC"])
        self.assertIn("--selected Same as macOS", args)
        self.assertIn("sudo -n try-omarchy-timezone --follow-mac", log)
        self.assertIn("follows macOS (Asia/Tokyo)", log)

    def test_a_zone_is_a_fixed_choice(self):
        options, args, log = self.pick("UTC", mode="fixed")
        self.assertIn("--selected Asia/Tokyo", args)
        self.assertIn("sudo -n try-omarchy-timezone --select UTC", log)

    def test_without_the_mac_channel_it_is_omarchys_list(self):
        options, _, log = self.pick("UTC", mac="")
        self.assertEqual(options, ["Asia/Tokyo", "UTC"])
        self.assertIn("--select UTC", log)

    def test_sudo_allows_only_the_pickers_commands(self):
        rule = (FILES / "etc/sudoers.d/try-omarchy-timezone").read_text()
        commands = [line.split("NOPASSWD: ", 1)[1] for line in rule.splitlines() if "NOPASSWD:" in line]
        self.assertEqual(commands[0], "/usr/bin/try-omarchy-timezone --follow-mac")
        pattern = commands[1].split(" ", 1)[1]
        self.assertTrue(pattern.startswith("^--select ") and pattern.endswith("$"))
        for allowed in ("--select UTC", "--select America/Argentina/Buenos_Aires", "--select Etc/GMT+3"):
            self.assertTrue(re.fullmatch(pattern[1:-1], allowed), allowed)
        for refused in ("--select ../../etc/passwd", "--select UTC --follow-mac", "--select /UTC", "--initialize"):
            self.assertFalse(re.fullmatch(pattern[1:-1], refused), refused)
        recipe = (PACKAGE / "PKGBUILD").read_text()
        self.assertIn('chmod 0440 "$pkgdir/etc/sudoers.d/"*', recipe)


class Ghostty(unittest.TestCase):
    WRAPPER = FILES / "usr/lib/try-omarchy/bin/ghostty"

    def launch(self, *args):
        tmp = Path(tempfile.mkdtemp())
        stub = tmp / "ghostty"
        stub.write_text('#!/bin/sh\necho "LIBGL_ALWAYS_SOFTWARE=$LIBGL_ALWAYS_SOFTWARE"\nprintf "%s\\n" "$@"\n')
        stub.chmod(0o755)
        result = subprocess.run([str(self.WRAPPER), *args], capture_output=True, text=True, check=True,
                                env={**os.environ, "TRY_OMARCHY_GHOSTTY": str(stub)})
        return result.stdout.splitlines()

    def test_ghostty_renders_in_software_and_its_shells_keep_the_gpu(self):
        self.assertEqual(self.launch("--gtk-single-instance=true", "-e", "htop"),
                         ["LIBGL_ALWAYS_SOFTWARE=1", "--env=LIBGL_ALWAYS_SOFTWARE=0",
                          "--gtk-single-instance=true", "-e", "htop"])
        # +actions must stay first.
        self.assertEqual(self.launch("+version"), ["LIBGL_ALWAYS_SOFTWARE=1", "+version"])

    def test_missing_ghostty_says_how_to_install_it(self):
        result = subprocess.run([str(self.WRAPPER)], capture_output=True, text=True,
                                env={**os.environ, "TRY_OMARCHY_GHOSTTY": "/nonexistent"})
        self.assertEqual(result.returncode, 127)
        self.assertIn("Install > Terminal > Ghostty", result.stderr)

    def test_every_launch_path_uses_the_wrapper(self):
        # The session takes PATH from the login shell, so it is set there;
        # environment.d keeps XDG_DATA_DIRS, which the shell leaves alone.
        environment = (FILES / "usr/lib/environment.d/90-try-omarchy.conf").read_text()
        self.assertNotIn("\nPATH=", environment)
        self.assertIn("XDG_DATA_DIRS=/usr/share/try-omarchy/xdg:", environment)
        profile = FILES / "etc/profile.d/try-omarchy.sh"
        twice = subprocess.run(["/bin/sh", "-c", f". {profile}; . {profile}; echo $PATH"], capture_output=True,
                               text=True, check=True, env={**os.environ, "PATH": "/usr/bin:/bin"})
        self.assertEqual(twice.stdout.strip(), "/usr/lib/try-omarchy/bin:/usr/bin:/bin")
        entry = configparser.ConfigParser(interpolation=None, strict=False)
        entry.optionxform = str
        entry.read(FILES / "usr/share/try-omarchy/ghostty/com.mitchellh.ghostty.desktop")
        for section in entry.sections():
            self.assertEqual(entry[section]["Exec"],
                             "/usr/lib/try-omarchy/bin/ghostty --gtk-single-instance=true", section)
        # Hidden until the Ghostty package is installed.
        self.assertEqual(entry["Desktop Entry"]["TryExec"], "/usr/bin/ghostty")
        self.assertEqual(entry["Desktop Entry"]["X-TerminalArgExec"], "-e")
        # Ghostty 1.3.1's unit, with the wrapper in place of /usr/bin/ghostty.
        drop_in = (FILES / "usr/lib/systemd/user/app-com.mitchellh.ghostty.service.d"
                   / "10-try-omarchy-software-gl.conf").read_text()
        self.assertIn("ExecStart=\nExecStart=/usr/lib/try-omarchy/bin/ghostty "
                      "--gtk-single-instance=true --initial-window=false\n", drop_in)
        # Stock notify-reload fails under systemd 262 (no SIGUSR2 handler at READY).
        self.assertIn("\nType=dbus\n", drop_in)


class GhosttyDesktopEntry(unittest.TestCase):
    SCRIPT = FILES / "usr/lib/try-omarchy/ghostty-desktop-entry"

    def run_script(self, installed, *args):
        tmp = Path(tempfile.mkdtemp())
        source = tmp / "ghostty/com.mitchellh.ghostty.desktop"
        source.parent.mkdir()
        source.write_text("[Desktop Entry]\n")
        ghostty = tmp / "ghostty-bin"
        if installed:
            ghostty.write_text("#!/bin/sh\n")
            ghostty.chmod(0o755)
        env = {"TRY_OMARCHY_GHOSTTY_ENTRY": str(source), "TRY_OMARCHY_XDG_APPLICATIONS": str(tmp / "xdg"),
               "TRY_OMARCHY_GHOSTTY": str(ghostty)}
        run(self.SCRIPT, *args, env=env)
        return tmp / "xdg/com.mitchellh.ghostty.desktop", source, env

    def test_entry_exists_only_while_ghostty_is_installed(self):
        # Omarchy's launcher ignores TryExec.
        link, source, env = self.run_script(installed=True)
        self.assertEqual(Path(os.readlink(link)), source)
        run(self.SCRIPT, env={**env, "TRY_OMARCHY_GHOSTTY": "/nonexistent"})
        self.assertFalse(link.is_symlink())
        link, _, env = self.run_script(installed=False)
        self.assertFalse(link.is_symlink())

    def test_remove_takes_the_link_away_before_the_package_goes(self):
        link, _, env = self.run_script(installed=True)
        run(self.SCRIPT, "--remove", env=env)
        self.assertFalse(link.is_symlink())

    def test_hooks_follow_ghostty_and_this_package(self):
        hooks = FILES / "usr/share/libalpm/hooks"
        after = (hooks / "try-omarchy-ghostty.hook").read_text()
        for line in ("Operation = Install", "Operation = Upgrade", "Operation = Remove",
                     "Target = usr/bin/ghostty", "Target = usr/lib/try-omarchy/ghostty-desktop-entry",
                     "When = PostTransaction", "Exec = /usr/lib/try-omarchy/ghostty-desktop-entry\n"):
            self.assertIn(line, after)
        before = (hooks / "try-omarchy-ghostty-remove.hook").read_text()
        self.assertIn("When = PreTransaction", before)
        self.assertIn("Exec = /usr/lib/try-omarchy/ghostty-desktop-entry --remove", before)
        self.assertIn('install -d "$pkgdir/usr/share/try-omarchy/xdg/applications"',
                      (PACKAGE / "PKGBUILD").read_text())


class Kitty(unittest.TestCase):
    WRAPPER = FILES / "usr/lib/try-omarchy/bin/kitty"

    def launch(self, *args):
        tmp = Path(tempfile.mkdtemp())
        stub = tmp / "kitty"
        stub.write_text('#!/bin/sh\necho "LIBGL_ALWAYS_SOFTWARE=$LIBGL_ALWAYS_SOFTWARE"\nprintf "%s\\n" "$@"\n')
        stub.chmod(0o755)
        return subprocess.run([str(self.WRAPPER), *args], capture_output=True, text=True, check=True,
                              env={**os.environ, "TRY_OMARCHY_KITTY": str(stub)}).stdout.splitlines()

    def test_kitty_renders_in_software_and_its_shells_do_not_inherit_it(self):
        # A bare env name leaves the variable empty (false to Mesa) in Kitty's children.
        self.assertEqual(self.launch("--title", "x", "-e", "htop"),
                         ["LIBGL_ALWAYS_SOFTWARE=1", "-o", "env=LIBGL_ALWAYS_SOFTWARE", "--title", "x", "-e", "htop"])
        # +kittens (the kitty-open desktop entry) and @ remote control stay first.
        self.assertEqual(self.launch("+open", "file"), ["LIBGL_ALWAYS_SOFTWARE=1", "+open", "file"])
        self.assertEqual(self.launch("@", "ls"), ["LIBGL_ALWAYS_SOFTWARE=1", "@", "ls"])


class TimedatectlShim(unittest.TestCase):
    def run_shim(self, *args, mac=True, select_ok=True):
        tmp = Path(tempfile.mkdtemp())
        log = tmp / "log"
        real = tmp / "timedatectl"
        real.write_text(f'#!/bin/sh\necho real "$@" >> "{log}"\n[ "$1" = list-timezones ] && printf "Asia/Tokyo\\nUTC\\n"\nexit 0\n')
        real.chmod(0o755)
        tool = tmp / "try-omarchy-timezone"
        tool.write_text("#!/bin/sh\n"
                        f'echo tool "$@" >> "{log}"\n'
                        f'[ "$1" = --mirror-label ] && {{ {"echo \"Same as macOS\"" if mac else "exit 1"}; exit $?; }}\n'
                        f'exit {0 if select_ok else 1}\n')
        tool.chmod(0o755)
        out = subprocess.run([str(LIB / "shims/timedatectl"), *args], capture_output=True, text=True, check=True,
                             env={**os.environ, "TRY_OMARCHY_TIMEDATECTL": str(real),
                                  "TRY_OMARCHY_TIMEZONE_COMMAND": str(tool)}).stdout.splitlines()
        return out, log.read_text().splitlines()

    def test_lists_same_as_macos_first(self):
        out, _ = self.run_shim("list-timezones")
        self.assertEqual(out, ["Same as macOS", "Asia/Tokyo", "UTC"])
        out, _ = self.run_shim("list-timezones", mac=False)
        self.assertEqual(out, ["Asia/Tokyo", "UTC"])

    def test_setup_choices_go_through_the_follow_policy(self):
        _, log = self.run_shim("set-timezone", "Same as macOS")
        self.assertEqual(log, ["tool --select Same as macOS"])
        _, log = self.run_shim("set-timezone", "Europe/Lisbon")
        self.assertEqual(log, ["tool --select Europe/Lisbon"])
        # If the policy tool can't apply it, the real command still gets the choice.
        _, log = self.run_shim("set-timezone", "Europe/Lisbon", select_ok=False)
        self.assertEqual(log, ["tool --select Europe/Lisbon", "real set-timezone Europe/Lisbon"])

    def test_everything_else_is_the_real_command(self):
        _, log = self.run_shim("show", "-p", "Timezone")
        self.assertEqual(log, ["real show -p Timezone"])

    def test_policy_tool_calls_the_real_command_by_path(self):
        tool = (FILES / "usr/bin/try-omarchy-timezone").read_text()
        self.assertIn('TIMEDATECTL = "/usr/bin/timedatectl"', tool)
        self.assertNotIn('["timedatectl"', tool)


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

    def test_preselects_same_as_macos_until_the_guest_chooses(self):
        self.assertEqual(self.run_shim(), "Same as macOS")
        self.assertEqual(self.run_shim({"mode": "auto", "zone": "Europe/Lisbon", "fingerprint": []}), "Same as macOS")
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


class AuthenticationState(unittest.TestCase):
    def setUp(self):
        self.broker = load(LIB / "native-authentication-broker", "broker")
        self.directory = Path(tempfile.mkdtemp()) / "try-omarchy"
        self.path = self.directory / "native-authentication.json"

    def save(self):
        self.broker.save_state(b"k" * 32, "a" * 64, self.path, enforce_root_owner=False)

    def test_pairing_keeps_the_shared_state_directory_usable_by_the_desktop_user(self):
        # The user checks that a pairing exists (1Password Touch ID) and reads
        # the time zone policy here; 0700 hid both.
        self.directory.mkdir(mode=0o700)
        self.save()
        self.assertEqual(stat.S_IMODE(self.directory.stat().st_mode), 0o755)
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
        self.assertEqual(json.loads(self.path.read_text())["guestId"], "a" * 64)

    def test_an_unsafe_directory_is_still_refused(self):
        self.directory.parent.mkdir(exist_ok=True)
        self.directory.symlink_to(self.directory.parent)
        with self.assertRaises(Exception):
            self.save()

    def test_boot_repairs_directories_earlier_packages_locked(self):
        rule = (FILES / "usr/lib/tmpfiles.d/try-omarchy.conf").read_text()
        self.assertIn("\nd /var/lib/try-omarchy 0755 root root -\n", rule)


class OnePassword(unittest.TestCase):
    def test_enables_the_shipped_unit(self):
        command = (FILES / "usr/bin/try-omarchy-onepassword-touch-id").read_text()
        self.assertIn('unit="try-omarchy-onepassword-touch-id@$user.service"', command)
        self.assertTrue((FILES / "usr/lib/systemd/system/try-omarchy-onepassword-touch-id@.service").is_file())
        self.assertIn("sudo systemctl enable --now", command)


class ImportPrevious(unittest.TestCase):
    """try-omarchy-import-previous against a fake, already mounted old disk."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.old = self.tmp / "previous"
        self.home = self.tmp / "home"
        self.home.mkdir()
        old_home = self.old / "home/dudas"
        for path in ("Documents/notes.txt", "projects/app/main.go", ".ssh/id_ed25519", ".gitconfig",
                     ".config/git/ignore", ".config/hypr/hyprland.conf", ".cache/big"):
            (old_home / path).parent.mkdir(parents=True, exist_ok=True)
            (old_home / path).write_text(path)
        (old_home / "Mac").symlink_to("/mnt/mac")  # the old shared-folder link
        (old_home / "Shared").mkdir()
        (self.home / "Shared").symlink_to("/mnt/mac")  # this VM's shared-folder link
        local = self.old / "var/lib/pacman/local"
        # The earlier image's packages were installed before its owner's home
        # existed (a birth time of 1000); the user's own after.
        log = []
        for name, reason, when in (("neovim", None, 2000), ("glibc", "1", 2000), ("htop", None, 2000),
                                   ("spotify", None, 2000), ("vulkan-swrast", None, 500),
                                   ("linux-aarch64", None, 2000), ("try-omarchy-runtime", None, 2000)):
            (local / f"{name}-1").mkdir(parents=True)
            desc = f"%NAME%\n{name}\n\n" + (f"%REASON%\n{reason}\n\n" if reason else "")
            (local / f"{name}-1/desc").write_text(desc)
            log.append(f"[{when}] [ALPM] installed {name} (1-1)\n")
        (self.old / "var/log").mkdir(parents=True)
        (self.old / "var/log/pacman.log").write_text("".join(log))
        self.log = self.tmp / "log"
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        for name, body in (("findmnt", "exit 0"), ("rsync", 'printf "%s\\n" "$@" >>"$TEST_LOG"'),
                           ("pacman", 'case $1 in -Qq) printf "glibc\\nneovim\\n" ;; -Slq) printf "htop\\nneovim\\n" ;;'
                                      ' *) printf "pacman %s\\n" "$*" >>"$TEST_LOG" ;; esac'),
                           # GNU stat's birth time and date -d, with plain seconds standing in for stamps.
                           ("stat", 'echo 1000'), ("date", 'echo "$2"')):
            (bin_dir / name).write_text(f"#!/bin/bash\n{body}\n")
            (bin_dir / name).chmod(0o755)
        self.env = {"HOME": str(self.home), "PATH": f"{bin_dir}:{os.environ['PATH']}", "TEST_LOG": str(self.log),
                    "TRY_OMARCHY_SUDO": "", "TRY_OMARCHY_PREVIOUS_MOUNT": str(self.old)}

    def run_import(self, *args):
        return subprocess.run([str(FILES / "usr/bin/try-omarchy-import-previous"), *args], capture_output=True,
                              text=True, check=True, env={**os.environ, **self.env})

    def test_copies_visible_files_and_portable_settings_without_replacing(self):
        self.run_import()
        args = self.log.read_text().splitlines()
        self.assertIn("--ignore-existing", args)
        self.assertEqual(args[-1], f"{self.home}/")
        old_home = self.old / "home/dudas"
        copied = sorted(arg.removeprefix(f"{old_home}/./") for arg in args if arg.startswith(f"{old_home}/./"))
        # Not the old Omarchy configuration, caches, nor through either shared-folder link.
        self.assertEqual(copied, [".config/git", ".gitconfig", ".ssh", "Documents", "projects"])

    def test_dry_run_and_user_choice(self):
        self.run_import("--dry-run", "--from", "dudas")
        self.assertIn("--dry-run", self.log.read_text().splitlines())
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_import("--from", "someone")

    def test_packages_installs_only_what_the_user_installed(self):
        result = self.run_import("--packages")
        self.assertEqual(self.log.read_text(), "pacman -S --needed htop\n")
        self.assertIn("spotify", result.stdout)
        for name in ("try-omarchy-runtime", "linux-aarch64", "vulkan-swrast"):
            self.assertNotIn(name, result.stdout)


if __name__ == "__main__":
    unittest.main()
