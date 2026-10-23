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
import sys
import tempfile
import time
import unittest
from unittest import mock

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

    def test_pinch_touchpad_alone_skips_libinput_jump_detection(self):
        quirks = (FILES / "usr/share/libinput/90-try-omarchy.quirks").read_text()
        sections = [line for line in quirks.splitlines() if line.startswith("[")]
        self.assertEqual(sections, ["[Try Omarchy Virtio Pinch Touchpad]"])
        self.assertIn("\nMatchName=QEMU Virtio Pinch Touchpad\n", quirks)
        self.assertIn("\nModelLenovoX1Gen6Touchpad=1\n", quirks)

    def test_platform_root_holds_only_the_camera_cutouts_link(self):
        # Generic aarch64 registers no platform package; the one file the VM
        # adds to Omarchy's platform root points at this boot's cutouts.
        lines = [line.strip() for line in (PACKAGE / "PKGBUILD").read_text().splitlines()
                 if "omarchy-platform" in line and not line.strip().startswith("#")]
        self.assertEqual(lines, [
            'install -d "$pkgdir/usr/share/omarchy-platform"',
            'ln -s /run/try-omarchy/display-cutouts.json "$pkgdir/usr/share/omarchy-platform/display-cutouts.json"',
        ])
        self.assertIn("/run/try-omarchy/display-cutouts.json", (LIB / "host-config").read_text())

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
        for bridge in ("audio", "camera", "clipboard", "dictation"):
            unit = configparser.ConfigParser(interpolation=None, strict=False)
            unit.read(FILES / f"usr/lib/systemd/user/omarchy-native-{bridge}-bridge.service")
            self.assertIn("graphical-session.target", unit["Unit"]["PartOf"].split())
            self.assertIn("graphical-session.target", unit["Unit"]["After"].split())
            self.assertEqual(unit["Install"]["WantedBy"], "graphical-session.target")

    def test_dictation_bridge_is_enabled_once_on_upgrade(self):
        install = (PACKAGE / "try-omarchy.install").read_text()
        self.assertIn("omarchy-native-dictation-bridge.service", install[:install.index("post_install()")])
        post_upgrade = install[install.index("post_upgrade()"):]
        self.assertIn('if [ "$(vercmp "$2" 0.1.0-37)" -lt 0 ]; then\n'
                      '    systemctl --global preset omarchy-native-dictation-bridge.service', post_upgrade)
        self.assertIn("pkgrel=37\n", (PACKAGE / "PKGBUILD").read_text())

    def test_dictation_bridge_waits_for_its_port(self):
        unit = configparser.ConfigParser(interpolation=None, strict=False)
        unit.read(FILES / "usr/lib/systemd/user/omarchy-native-dictation-bridge.service")
        self.assertEqual(unit["Unit"]["ConditionPathExists"], "/dev/virtio-ports/dev.tryomarchy.dictation")
        self.assertEqual(unit["Service"]["ExecStart"], "/usr/bin/omarchy-native-dictation-bridge")
        rule = (FILES / "usr/lib/udev/rules.d/70-try-omarchy-dictation.rules").read_text()
        self.assertIn('ATTR{name}=="dev.tryomarchy.dictation", GROUP="users", MODE="0660", TAG+="uaccess"', rule)

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
        self.cutouts = self.tmp / "run/try-omarchy/display-cutouts.json"
        self.env = {"CREDENTIALS_DIRECTORY": str(self.credentials), "TRY_OMARCHY_HOST_CONFIG_OUTPUT": str(self.output),
                    "TRY_OMARCHY_DISPLAY_CUTOUTS_OUTPUT": str(self.cutouts)}

    def test_publishes_tokens(self):
        (self.credentials / "tryomarchy.host").write_text("omarchy.qemu_virgl=1 tryomarchy.keyboard=jis\n")
        run(LIB / "host-config", env=self.env)
        self.assertEqual(self.output.read_text(), "omarchy.qemu_virgl=1 tryomarchy.keyboard=jis\n")
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o644)

    def test_without_credential_writes_nothing(self):
        run(LIB / "host-config", env=self.env)
        self.assertFalse(self.output.exists())
        self.assertFalse(self.cutouts.exists())

    def test_describes_the_macs_camera_housing_to_omarchy(self):
        (self.credentials / "tryomarchy.host").write_text(
            "omarchy.qemu_virgl=1 tryomarchy.display_cutouts=3024x1964:64,2048x1330:44 tryomarchy.keyboard=ansi\n")
        run(LIB / "host-config", env=self.env)
        # The schema Omarchy's bar parses (BarModel.parseCutouts): QEMU's
        # first output, every panel mode with the housing in physical pixels.
        self.assertEqual(json.loads(self.cutouts.read_text()), {"panels": [
            {"connector": "Virtual-1", "width": 3024, "height": 1964, "top": 64},
            {"connector": "Virtual-1", "width": 2048, "height": 1330, "top": 44},
        ]})
        self.assertEqual(stat.S_IMODE(self.cutouts.stat().st_mode), 0o644)

    def test_no_housing_or_a_malformed_one_describes_none(self):
        self.cutouts.parent.mkdir(parents=True)
        for value in ("tryomarchy.keyboard=ansi",
                      "tryomarchy.display_cutouts=3024x1964:64,",
                      "tryomarchy.display_cutouts=3024x1964:0",
                      'tryomarchy.display_cutouts=3024x1964:64"}]',
                      "tryomarchy.display_cutouts=3024x1964"):
            self.cutouts.write_text("stale\n")
            (self.credentials / "tryomarchy.host").write_text(value + "\n")
            run(LIB / "host-config", env=self.env)
            self.assertFalse(self.cutouts.exists(), value)
            self.assertEqual(self.output.read_text(), value + "\n")

    def test_rejects_control_characters_and_oversize(self):
        (self.credentials / "tryomarchy.host").write_bytes(b"a\x1bb")
        self.assertNotEqual(run(LIB / "host-config", env=self.env, check=False).returncode, 0)
        (self.credentials / "tryomarchy.host").write_text("x" * 20000)
        self.assertNotEqual(run(LIB / "host-config", env=self.env, check=False).returncode, 0)
        self.assertFalse(self.output.exists())


class NotchRefresh(unittest.TestCase):
    """notch-refresh nudges Quickshell only when the cutout's answer can change."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.cutouts = self.tmp / "display-cutouts.json"
        self.log = self.tmp / "hyprctl.log"
        shims = self.tmp / "bin"
        shims.mkdir()
        (shims / "hyprctl").write_text('#!/bin/bash\necho "$*" >>"$HYPRCTL_LOG"\n')
        (shims / "hyprctl").chmod(0o755)
        self.env = {"PATH": f"{shims}:{os.environ['PATH']}", "HYPRCTL_LOG": str(self.log),
                    "TRY_OMARCHY_DISPLAY_CUTOUTS": str(self.cutouts),
                    "TRY_OMARCHY_NOTCH_STATE": str(self.tmp / "state/notch-mode")}

    def nudges(self, mode):
        before = self.log.read_text().count("create") if self.log.exists() else 0
        run(LIB / "notch-refresh", mode, env=self.env)
        return self.log.read_text().count("create") - before if self.log.exists() else 0

    def test_only_entering_leaving_or_changing_a_notch_mode_nudges(self):
        (self.credentials_dir() / "tryomarchy.host").write_text(
            "tryomarchy.display_cutouts=3600x2338:77,3024x1964:64\n")
        run(LIB / "host-config", env={"CREDENTIALS_DIRECTORY": str(self.credentials_dir()),
                                     "TRY_OMARCHY_HOST_CONFIG_OUTPUT": str(self.tmp / "cmdline"),
                                     "TRY_OMARCHY_DISPLAY_CUTOUTS_OUTPUT": str(self.cutouts)})
        self.assertEqual(self.nudges("1940x1260"), 0)   # a window at first
        self.assertEqual(self.nudges("3024x1964"), 1)   # full screen covers the notch
        self.assertEqual(self.nudges("3024x1964"), 0)   # nothing changed
        self.assertEqual(self.nudges("3600x2338"), 1)   # another resolution
        self.assertEqual(self.nudges("1940x1260"), 1)   # back to a window
        self.assertEqual(self.nudges("1800x1100"), 0)   # a window resized
        self.assertEqual(self.log.read_text().splitlines()[-2:],
                         ["output create headless TRYOMARCHY-REFRESH", "output remove TRYOMARCHY-REFRESH"])

    def test_a_mac_without_a_notch_or_a_bad_mode_does_nothing(self):
        self.assertEqual(self.nudges("3024x1964"), 0)
        result = run(LIB / "notch-refresh", "3024x1964;reboot", env=self.env, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.log.exists())

    def test_display_sync_passes_each_applied_mode(self):
        sync = (FILES / "usr/bin/omarchy-native-display-sync").read_text()
        self.assertIn('"$notch_refresh" "${width}x$height" || true', sync)
        # Only after Hyprland accepted the mode.
        self.assertLess(sync.index('elif [[ $response != ok ]]'), sync.index('"$notch_refresh"'))

    def credentials_dir(self):
        path = self.tmp / "credentials"
        path.mkdir(exist_ok=True)
        return path


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
  "appearance.top-bar.indicators.battery-percentage-on": {"icon":"\U000f0079","label":"Show Battery Percentage","when":"omarchy-hw-laptop && [[ $(omarchy-bar get omarchy.power showPercentage) != true ]]","action":"omarchy-shell omarchy.power togglePercentage"},
  "appearance.top-bar.indicators.battery-percentage-off": {"icon":"\U000f0079","label":"Hide Battery Percentage","when":"omarchy-hw-laptop && [[ $(omarchy-bar get omarchy.power showPercentage) == true ]]","action":"omarchy-shell omarchy.power togglePercentage"},
  "install.gaming.geforce-now": {"icon":"\U000f08b9","label":"NVIDIA GeForce NOW","disabled":"flatpak info com.nvidia.geforcenow","action":"omarchy-launch-floating-terminal-with-presentation omarchy-install-gaming-geforce-now"},
  "install.gaming.battlenet": {"icon":"","label":"Battle.net","disabled":"[[ -d $HOME/Games/battlenet ]]","action":"omarchy-launch-floating-terminal-with-presentation omarchy-install-gaming-battlenet"},
  "install.gaming.lutris": {"icon":"","label":"Lutris","disabled":"omarchy-pkg-present lutris","action":"omarchy-launch-floating-terminal-with-presentation omarchy-install-gaming-lutris"},
  "remove.dictation": {"icon":"","label":"Dictation","when":"omarchy-pkg-present voxtype-bin || omarchy-pkg-present superwhisper-bin"},
}
"""
    OWN = {"setup.try-omarchy", "setup.security.touch-id", "setup.security.onepassword-touch-id",
           "setup.import-previous-vm", "setup.default.dictation.apple-speech", "remove.dictation.apple-speech"}
    DICTATION = {"setup.default.dictation.apple-speech", "remove.dictation.apple-speech", "remove.dictation"}
    CHANGED = {"update.timezone", "setup.direct-boot", "update.firmware", "update.hardware.wifi",
               "update.hardware.bluetooth", "appearance.top-bar.indicators.battery-percentage-on",
               "appearance.top-bar.indicators.battery-percentage-off",
               "install.gaming.geforce-now", "install.gaming.battlenet", "install.gaming.lutris",
               "remove.dictation"}

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
                # Remove > Dictation is a submenu: Omarchy's row has no action.
                if field in omarchy[key] and (field != "action" or key != "update.timezone"):
                    self.assertEqual(parsed[key][field], omarchy[key][field], (key, field))
        self.assertIn("/usr/bin/try-omarchy-timezone-menu", parsed["update.timezone"]["action"])
        self.assertEqual(parsed["setup.direct-boot"]["when"],
                         "! omarchy-hw-vm && (! omarchy-hw-aarch64-apple && "
                         "[[ ! -f /etc/limine-entry-tool.d/zz-omarchy-dgx-spark.conf ]])")
        self.assertEqual(parsed["update.firmware"]["when"], "! omarchy-hw-vm")
        self.assertEqual(parsed["install.gaming.lutris"]["when"], "omarchy-hw-x86")
        self.assertEqual(parsed["install.gaming.lutris"]["disabled"], "omarchy-pkg-present lutris")
        self.assertEqual(parsed["appearance.top-bar.indicators.battery-percentage-on"]["when"],
                         "(omarchy-hw-laptop || compgen -G '/sys/class/power_supply/BAT*' >/dev/null) && "
                         "[[ $(omarchy-bar get omarchy.power showPercentage) != true ]]")
        # Removed rows stay removed.
        self.menu.write_text("{}\n")
        self.entries()
        self.assertEqual(self.menu.read_text(), "{}\n")

    def test_apple_speech_rows_show_only_while_they_can_work(self):
        self.entries()
        parsed = self.parse(self.menu.read_text())
        choose = parsed["setup.default.dictation.apple-speech"]
        self.assertEqual(choose["when"], "test -e /dev/virtio-ports/dev.tryomarchy.dictation")
        self.assertEqual(choose["action"], "omarchy-default-dictation apple-speech")
        self.assertEqual(choose["checked"], '[[ "$(omarchy-default-dictation)" == "apple-speech" ]]')
        remove = parsed["remove.dictation.apple-speech"]
        chosen = 'test -s "${XDG_STATE_HOME:-$HOME/.local/state}/try-omarchy/dictation-backend"'
        self.assertEqual(remove["when"], chosen)
        self.assertEqual(remove["action"],
                         "omarchy-launch-floating-terminal-with-presentation omarchy-remove-dictation-apple-speech")
        # Omarchy shows its Remove > Dictation menu only for its own backends.
        self.assertEqual(parsed["remove.dictation"]["when"],
                         "(omarchy-pkg-present voxtype-bin || omarchy-pkg-present superwhisper-bin) || " + chosen)
        self.assertEqual(parsed["remove.dictation"]["label"], "Dictation")

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
        # Nothing re-added; only rows of later releases are new.
        self.assertEqual(set(parsed), {"update.firmware", "update.hardware.wifi", "setup.import-previous-vm",
                                       "appearance.top-bar.indicators.battery-percentage-on",
                                       "appearance.top-bar.indicators.battery-percentage-off"}
                         | self.DICTATION)

    def test_dictation_rows_reach_menus_written_by_the_battery_release(self):
        self.menu.parent.mkdir(parents=True)
        self.menu.write_text("{\n}\n")
        self.state.mkdir(parents=True)
        (self.state / "menu-entries").write_text("8\n")
        self.entries()
        self.assertEqual(set(self.parse(self.menu.read_text())), self.DICTATION)
        self.assertEqual((self.state / "menu-entries").read_text(), "9\n")

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
                         {"setup.security.onepassword-touch-id", "setup.import-previous-vm"} | self.DICTATION
                         | self.CHANGED)
        self.entries()
        self.assertEqual(len(self.parse(self.menu.read_text())), 4 + len(self.CHANGED))
        self.assertEqual(self.menu.read_text().count("// Try Omarchy:"), 1)

    def test_an_existing_header_is_not_repeated(self):
        self.menu.parent.mkdir(parents=True)
        self.menu.write_text("{\n  // Try Omarchy: Mac app settings and Touch ID (added once each; safe to remove).\n}\n")
        self.state.mkdir(parents=True)
        (self.state / "menu-entries").write_text("2\n")
        self.entries()
        text = self.menu.read_text()
        self.assertEqual(set(self.parse(text)), {"setup.import-previous-vm"} | self.DICTATION | self.CHANGED)
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

    def test_the_settings_row_and_desktop_entry_say_try_omarchy(self):
        self.entries()
        self.assertEqual(self.parse(self.menu.read_text())["setup.try-omarchy"]["label"], "Try Omarchy Settings")
        entry = configparser.ConfigParser(interpolation=None)
        entry.optionxform = str
        entry.read(FILES / "usr/share/applications/try-omarchy-settings.desktop")
        self.assertEqual(entry["Desktop Entry"]["Name"], "Try Omarchy Settings")


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


class ClockRecovery(unittest.TestCase):
    def recover(self, rtc_name):
        module = load(LIB / "guest-clock-recover", "guest_clock_recover")
        files = {"/run/try-omarchy/cmdline": "omarchy.qemu_virgl=1\n",
                 "/sys/class/rtc/rtc0/name": rtc_name,
                 "/sys/class/rtc/rtc0/since_epoch": "1792335311\n"}
        with mock.patch("os.geteuid", return_value=0), \
             mock.patch("pathlib.Path.read_text", autospec=True, side_effect=lambda p: files[str(p)]), \
             mock.patch("time.time", return_value=1792335311 - 3600), \
             mock.patch("time.monotonic", side_effect=[100, 100.1]), \
             mock.patch("time.clock_settime", create=True) as step, \
             mock.patch("subprocess.run") as run:
            result = module.recover()
            self.calls = [call.args[0][2:] for call in run.call_args_list]
            return result, step.called

    def test_steps_forward_from_the_pl031_under_either_driver(self):
        # UEFI boots reach the PL031 through firmware runtime services (#389).
        for name in ("rtc-pl031 9010000.pl031\n", "rtc-efi rtc-efi.0\n"):
            with self.subTest(name=name):
                self.assertEqual(self.recover(name), (True, True))

    def test_a_step_redraws_the_bar_clock_and_resyncs_ntp(self):
        self.recover("rtc-efi rtc-efi.0\n")
        self.assertEqual(self.calls, [["restart", "try-omarchy-clock-refresh.service"],
                                      ["try-restart", "systemd-timesyncd.service"]])

    def test_other_clocks_are_not_trusted(self):
        self.assertEqual(self.recover("rtc-cmos 00:01\n"), (False, False))
        self.assertEqual(self.calls, [])

    def test_the_refresh_runs_outside_the_recovery_sandbox(self):
        # runuser needs more than CAP_SYS_TIME, and the shell lives in ~.
        units = FILES / "usr/lib/systemd/system"
        recovery = (units / "try-omarchy-clock-recovery.service").read_text()
        self.assertIn("CapabilityBoundingSet=CAP_SYS_TIME", recovery)
        refresh = (units / "try-omarchy-clock-refresh.service").read_text()
        self.assertIn("ExecStart=/usr/lib/try-omarchy/clock-refresh --after-step\n", refresh)
        self.assertNotIn("CapabilityBoundingSet", refresh)
        self.assertNotIn("[Install]", refresh)  # started only by the recovery


class ClockRefresh(unittest.TestCase):
    def setUp(self):
        self.module = load(LIB / "clock-refresh", "clock_refresh")

    def run_main(self, arguments, now):
        events = []
        with mock.patch("time.time", return_value=now):
            self.module.main(arguments, refresh=lambda: events.append("refresh"),
                             sleep=lambda seconds: events.append(round(seconds, 2)))
        return events

    def test_a_refresh_after_a_step_repeats_on_the_next_minute(self):
        # The bar's SystemClock may still be armed for a minute from before
        # the step; the second redraw covers the one minute it can miss.
        self.assertEqual(self.run_main(["--after-step"], 1792335311.5), ["refresh", 48.75, "refresh"])
        self.assertEqual(self.run_main(["--after-step"], 1792335359.9), ["refresh", 0.35, "refresh"])

    def test_a_plain_refresh_redraws_once(self):
        self.assertEqual(self.run_main([], 1792335311.5), ["refresh"])
        with self.assertRaises(SystemExit):
            self.run_main(["--now"], 1792335311.5)


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

    def test_upgrade_from_before_the_cutouts_reruns_host_config(self):
        # The boot that upgrades an older VM ran the old host-config, which
        # wrote no cutouts; the desktop starts after the upgrade.
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            log = tmp / "calls"
            (tmp / "systemctl").write_text('#!/bin/bash\nprintf "%s\\n" "$*" >>"$TEST_LOG"\n')
            (tmp / "vercmp").write_text('#!/usr/bin/python3\nimport re, sys\n'
                                        'a, b = (tuple(map(int, re.split(r"[.-]", v))) for v in sys.argv[1:3])\n'
                                        'print((a > b) - (a < b))\n')
            for tool in ("systemctl", "vercmp"):
                (tmp / tool).chmod(0o755)
            for old, restarted in (("0.1.0-27", True), ("0.1.0-28", False)):
                log.write_text("")
                subprocess.run(["/bin/bash", "-c", 'source "$1"; post_upgrade 0.1.0-28 "$2"', "bash",
                                str(PACKAGE / "try-omarchy.install"), old], check=True, env={
                    **os.environ, "PATH": f"{tmp}:{os.environ['PATH']}", "TEST_LOG": str(log)})
                self.assertEqual("try-restart try-omarchy-host-config.service" in log.read_text().splitlines(),
                                 restarted, old)
        unit = (PACKAGE / "files/usr/lib/systemd/system/try-omarchy-host-config.service").read_text()
        self.assertIn("RemainAfterExit=yes", unit)
        install = (PACKAGE / "files/usr/lib/systemd/system/try-omarchy-package-install.service").read_text()
        self.assertIn("Before=display-manager.service", install)


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

    def test_cpu_drop_in_hides_sme_without_sve(self):
        # The M4 has SME but no SVE; QEMU under HVF cannot hide SME.
        text = (FILES / "etc/limine-entry-tool.d/50-try-omarchy-cpu.conf").read_text()
        lines = [line for line in text.splitlines() if line.startswith("KERNEL_CMDLINE[default]+=")]
        self.assertEqual(lines, ['KERNEL_CMDLINE[default]+=" arm64.nosme"'])
        self.assertIn("'etc/limine-entry-tool.d/50-try-omarchy-cpu.conf'", (PACKAGE / "PKGBUILD").read_text())

    def test_upgrade_rebuilds_limine_once_where_the_kernel_shows_sme(self):
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            log = tmp / "calls"
            limine = tmp / "limine.conf"
            limine.write_text("")
            for name in ("limine-update", "systemctl"):
                (tmp / name).write_text(f'#!/bin/bash\nprintf "%s\\n" "{name} $*" >>"$TEST_LOG"\n')
                (tmp / name).chmod(0o755)
            cpuinfo, cmdline = tmp / "cpuinfo", tmp / "cmdline"
            for features, running, boot, expected in (
                ("fp asimd sme sme2", "quiet", limine, ["limine-update "]),
                ("fp asimd sme sme2", "quiet arm64.nosme", limine, []),
                ("fp asimd sme2", "quiet", limine, []),
                ("fp asimd", "quiet", limine, []),
                ("fp asimd sme", "quiet", tmp / "missing.conf", []),
            ):
                log.write_text("")
                cpuinfo.write_text(f"Features\t: {features}\n")
                cmdline.write_text(running + "\n")
                subprocess.run(["/bin/bash", "-c", 'source "$1"; _hide_sme "$2" "$3" "$4"', "bash",
                                str(PACKAGE / "try-omarchy.install"), cpuinfo, cmdline, boot], check=True,
                               env={**os.environ, "PATH": f"{tmp}:{os.environ['PATH']}", "TEST_LOG": str(log)})
                calls = [line for line in log.read_text().splitlines() if line.startswith("limine-update")]
                self.assertEqual(calls, expected, (features, running, boot.name))
        install = (PACKAGE / "try-omarchy.install").read_text()
        self.assertIn('if [ "$(vercmp "$2" 0.1.0-27)" -lt 0 ]; then\n    _hide_sme\n', install)

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

    def mode_keys(self):
        return self.module.initialize_mode_keys(self.config, self.tmp / "state/try-omarchy/fcitx-mode-keys-v1")

    def test_adds_the_mac_switch_keys_to_an_older_profile_once(self):
        self.config.parent.mkdir()
        self.config.write_text("[Hotkey/TriggerKeys]\n0=Control+space\n\n[Hotkey/ActivateKeys]\n0=Hangul_Hanja\n\n"
                               "[Behavior]\nActiveByDefault=False\n")
        self.assertTrue(self.mode_keys())
        text = self.config.read_text()
        self.assertEqual(self.module.section_values(text, "Hotkey/ActivateKeys"), ["Hangul_Hanja", "Henkan"])
        self.assertEqual(self.module.section_values(text, "Hotkey/DeactivateKeys"), ["Muhenkan"])
        self.assertEqual(self.module.section_values(text, "Hotkey/TriggerKeys"), ["Control+space"])
        self.assertIn("ActiveByDefault=False", text)
        self.config.write_text("[Hotkey/ActivateKeys]\n0=Hangul_Hanja\n")
        self.assertFalse(self.mode_keys())
        self.assertEqual(self.config.read_text(), "[Hotkey/ActivateKeys]\n0=Hangul_Hanja\n")

    def test_leaves_current_profiles_and_waits_for_a_missing_one(self):
        self.assertFalse(self.mode_keys())
        self.assertFalse(self.config.exists())
        self.config.parent.mkdir()
        self.config.write_text(self.STOCK)
        self.assertTrue(self.mode_keys())
        self.assertEqual(self.config.read_text(), self.STOCK)


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
        self.link("Asia/Tokyo")  # Same as macOS, the setup form's default
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

    def test_a_mac_wake_checks_the_clock_and_nothing_else(self):
        recovered = []
        with mock.patch.object(self.module, "follow") as follow:
            self.module.handle({"type": "wake"}, recover=lambda: recovered.append(True))
            follow.assert_not_called()
        self.assertEqual(recovered, [True])
        for message in ({"type": "wake", "zone": "UTC"}, {"type": "wake", "time": 1792335311},
                        {"type": "clock"}, ["wake"]):
            with self.subTest(message=message), self.assertRaises(ValueError):
                self.module.handle(message, recover=lambda: recovered.append(message))
        self.assertEqual(recovered, [True])

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


class SetupFormDefaults(unittest.TestCase):
    def defaults(self, mode="follow", mac=True, stale=False):
        tmp = Path(tempfile.mkdtemp())
        environment = tmp / "run/setup-form.env"
        if stale:
            environment.parent.mkdir()
            environment.write_text('OMARCHY_FORM_TIMEZONE_DEFAULT="Same as macOS"\n')
        tool = tmp / "try-omarchy-timezone"
        tool.write_text("#!/bin/sh\n"
                        f'[ "$1" = --mirror-label ] && {{ {"echo \"Same as macOS\"" if mac else "exit 1"}; exit $?; }}\n'
                        f'[ "$1" = --mode ] && echo {mode}\n')
        tool.chmod(0o755)
        subprocess.run([str(LIB / "setup-form-defaults")], check=True,
                       env={**os.environ, "TRY_OMARCHY_SETUP_FORM_ENV": str(environment),
                            "TRY_OMARCHY_TIMEZONE_COMMAND": str(tool)})
        return environment.read_text() if environment.exists() else None

    def test_preselects_same_as_macos_until_the_guest_chooses(self):
        self.assertEqual(self.defaults(), 'OMARCHY_FORM_TIMEZONE_DEFAULT="Same as macOS"\n')
        self.assertIsNone(self.defaults(mode="fixed", stale=True))
        self.assertIsNone(self.defaults(mac=False, stale=True))

    def test_only_owner_setup_sees_it(self):
        drop_in = (FILES / "usr/lib/systemd/system/omarchy-provision-owner.service.d"
                   / "10-try-omarchy-native.conf").read_text()
        self.assertIn("Environment=PATH=/usr/lib/try-omarchy/shims:", drop_in)
        self.assertIn("ExecStartPre=-/usr/lib/try-omarchy/setup-form-defaults\n", drop_in)
        self.assertIn("EnvironmentFile=-/run/try-omarchy/setup-form.env\n", drop_in)
        self.assertIn("/run/try-omarchy/setup-form.env", (LIB / "setup-form-defaults").read_text())


class Hyprland(unittest.TestCase):
    def test_cursor_is_hidden_again_after_the_screensaver(self):
        profile = (FILES / "usr/share/try-omarchy/hyprland.lua").read_text()
        handler = profile[profile.index('hl.on("window.destroy"'):]
        self.assertIn("invisible = true", handler[:200])

    def test_italian_on_apple_models_is_current_qwerty(self):
        # xkeyboard-config's Apple Italian is the old QZERTY layout, where M types
        # a comma; guest/tests/package-install.sh compiles the keymaps.
        symbols = (FILES / "etc/xkb/symbols/macintosh_vndr/it").read_text()
        self.assertEqual(re.findall(r'^default\s+xkb_symbols "(\w+)"', symbols, re.M), ["basic"])
        self.assertIn('include "it(basic)"', symbols)


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


class DictationBridge(unittest.TestCase):
    """The guest end of dev.tryomarchy.dictation, with a pty as the port and
    the test as the Mac's dictation bridge on its other side."""

    BRIDGE = FILES / "usr/bin/omarchy-native-dictation-bridge"

    def setUp(self):
        import pty
        import tty
        self.runtime = tempfile.TemporaryDirectory()
        self.host, port = pty.openpty()
        tty.setraw(port)
        self.port_fd = port
        self.port_path = os.ttyname(port)
        self.socket_path = os.path.join(self.runtime.name, "apple-dictation.sock")
        self.pending = b""
        self.process = None
        self.clients = []

    def tearDown(self):
        for client in self.clients:
            client.close()
        if self.process and self.process.poll() is None:
            self.process.kill()
        if self.process:
            self.process.wait(timeout=5)
            self.process.stderr.close()
        for descriptor in (self.host, self.port_fd):
            try:
                os.close(descriptor)
            except OSError:
                pass
        self.runtime.cleanup()

    def start(self, port_path=None):
        env = {**os.environ, "XDG_RUNTIME_DIR": self.runtime.name,
               "OMARCHY_DICTATION_PORT": port_path or self.port_path}
        self.process = subprocess.Popen([sys.executable, str(self.BRIDGE)], env=env,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    def started(self):
        self.start()
        self.assertEqual(self.host_read(), {"type": "hello", "version": 1})

    def host_read(self, timeout=2.0):
        import select
        deadline = time.monotonic() + timeout
        while b"\n" not in self.pending:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.host], [], [], remaining)[0]:
                return None
            try:
                chunk = os.read(self.host, 65536)
            except OSError:
                return None
            if not chunk:
                return None
            self.pending += chunk
        line, self.pending = self.pending.split(b"\n", 1)
        return json.loads(line)

    def host_send(self, **message):
        os.write(self.host, (json.dumps(message) + "\n").encode())

    def client(self):
        import socket
        deadline = time.monotonic() + 3
        while not os.path.exists(self.socket_path):
            self.assertLess(time.monotonic(), deadline, "the bridge never served its socket")
            time.sleep(0.01)
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(3)
        client.connect(self.socket_path)
        self.clients.append(client)
        return client

    def request(self, **message):
        client = self.client()
        client.sendall((json.dumps(message) + "\n").encode())
        return client

    @staticmethod
    def client_read(client, timeout=3.0):
        """The next line as JSON, or "EOF" when the bridge closed the connection."""
        import socket
        client.settimeout(timeout)
        data = b""
        while b"\n" not in data:
            try:
                chunk = client.recv(65536)
            except socket.timeout:
                return None
            if not chunk:
                return "EOF" if not data else json.loads(data)
            data += chunk
        return json.loads(data.split(b"\n", 1)[0])

    def read_events(self, client, count):
        events = []
        buffer = b""
        client.settimeout(3)
        while len(events) < count:
            while b"\n" not in buffer:
                chunk = client.recv(65536)
                if not chunk:
                    events.append("EOF")
                    return events
                buffer += chunk
            line, buffer = buffer.split(b"\n", 1)
            events.append(json.loads(line))
        rest = client.recv(65536)
        if not rest:
            events.append("EOF")
        return events

    def test_says_hello_on_open(self):
        self.started()
        self.client()
        self.assertEqual(stat.S_IMODE(os.stat(self.socket_path).st_mode), 0o600)

    def test_start_streams_until_final(self):
        self.started()
        owner = self.request(cmd="start", model="dictation")
        self.assertEqual(self.host_read(), {"type": "start", "session": 1, "model": "dictation"})
        self.host_send(type="recording", session=1)
        self.host_send(type="partial", session=1, text="hi")
        self.host_send(type="final", session=1, text="hi", ms=90)
        self.assertEqual(self.read_events(owner, 3), [
            {"event": "recording"}, {"event": "partial", "text": "hi"},
            {"event": "final", "text": "hi", "ms": 90}, "EOF"])

    def test_stop_and_cancel_reply_ok_and_reach_host(self):
        self.started()
        self.request(cmd="start")
        self.assertEqual(self.host_read()["type"], "start")
        self.assertEqual(self.read_events(self.request(cmd="stop"), 1), [{"ok": True}, "EOF"])
        self.assertEqual(self.host_read(), {"type": "stop", "session": 1})
        # Stop handed session 1 to finishing, so a cancel now has no live
        # session to act on.
        self.assertEqual(self.read_events(self.request(cmd="cancel"), 1), [{"ok": True}, "EOF"])
        self.assertIsNone(self.host_read(timeout=0.5))
        self.request(cmd="start")
        self.assertEqual(self.host_read()["session"], 2)
        self.assertEqual(self.read_events(self.request(cmd="cancel"), 1), [{"ok": True}, "EOF"])
        self.assertEqual(self.host_read(), {"type": "cancel", "session": 2})

    def test_ping_round_trips_and_times_out(self):
        self.started()
        pinger = self.request(cmd="ping")
        ping = self.host_read()
        self.assertEqual(ping["type"], "ping")
        self.host_send(type="pong", id=ping["id"])
        self.assertEqual(self.read_events(pinger, 1), [{"ok": True, "session": False}, "EOF"])
        silent = self.request(cmd="ping")
        self.assertEqual(self.host_read()["type"], "ping")
        self.assertEqual(self.read_events(silent, 1), [{"ok": False, "error": "host not responding"}, "EOF"])

    def test_ping_reports_a_session_only_while_it_records(self):
        self.started()
        self.request(cmd="start")
        self.assertEqual(self.host_read()["session"], 1)

        def ping(live):
            pinger = self.request(cmd="ping")
            sent = self.host_read()
            self.host_send(type="pong", id=sent["id"], **({"session": live} if live else {}))
            return self.read_events(pinger, 1)[0]["session"]

        self.assertTrue(ping(1))
        self.request(cmd="stop")
        self.assertEqual(self.host_read()["type"], "stop")
        # The Mac still finishes session 1, so a toggle now must start the next one.
        self.assertFalse(ping(1))
        self.request(cmd="start")
        self.assertEqual(self.host_read()["session"], 2)
        self.assertFalse(ping(None))  # the Mac lost session 2

    def test_second_start_cancels_first_owner(self):
        self.started()
        first = self.request(cmd="start")
        self.assertEqual(self.host_read()["session"], 1)
        self.request(cmd="start")
        self.assertEqual(self.read_events(first, 1), [{"event": "cancelled"}, "EOF"])
        self.assertEqual(self.host_read(), {"type": "start", "session": 2, "model": "speech"})

    def test_owner_hangup_cancels_on_host(self):
        self.started()
        owner = self.request(cmd="start")
        self.assertEqual(self.host_read()["type"], "start")
        owner.close()
        self.assertEqual(self.host_read(), {"type": "cancel", "session": 1})

    def test_owner_close_after_final_sends_nothing(self):
        self.started()
        owner = self.request(cmd="start")
        self.host_read()
        self.host_send(type="final", session=1, text="", ms=1)
        self.assertEqual(self.read_events(owner, 1), [{"event": "final", "text": "", "ms": 1}, "EOF"])
        owner.close()
        self.assertIsNone(self.host_read(timeout=0.5))

    def test_stop_before_recording_is_forwarded(self):
        self.started()
        owner = self.request(cmd="start")
        self.assertEqual(self.read_events(self.request(cmd="stop"), 1), [{"ok": True}, "EOF"])
        self.assertEqual(self.host_read(), {"type": "start", "session": 1, "model": "speech"})
        self.assertEqual(self.host_read(), {"type": "stop", "session": 1})
        self.host_send(type="recording", session=1)
        self.host_send(type="processing", session=1)
        self.host_send(type="final", session=1, text="quick", ms=40)
        self.assertEqual(self.read_events(owner, 3), [
            {"event": "recording"}, {"event": "processing"},
            {"event": "final", "text": "quick", "ms": 40}, "EOF"])

    def test_live_session_times_out_without_host_events(self):
        self.started()
        owner = self.request(cmd="start")
        self.host_read()
        self.assertEqual(self.client_read(owner, timeout=7), {"event": "error", "message": "host not responding"})

    def test_host_eof_ends_session_with_error(self):
        self.started()
        owner = self.request(cmd="start")
        self.host_read()
        os.close(self.host)
        self.assertEqual(self.client_read(owner), {"event": "error", "message": "host went away"})
        self.assertEqual(self.process.wait(timeout=5), 1)

    def test_pressing_again_while_finishing_keeps_the_first_final(self):
        self.started()
        first = self.request(cmd="start")
        self.host_read()
        self.assertEqual(self.read_events(self.request(cmd="stop"), 1), [{"ok": True}, "EOF"])
        self.assertEqual(self.host_read(), {"type": "stop", "session": 1})
        second = self.request(cmd="start")
        self.assertEqual(self.host_read(), {"type": "start", "session": 2, "model": "speech"})
        self.host_send(type="final", session=1, text="first", ms=200)
        self.assertEqual(self.read_events(first, 1), [{"event": "final", "text": "first", "ms": 200}, "EOF"])
        self.host_send(type="final", session=2, text="second", ms=100)
        self.assertEqual(self.read_events(second, 1), [{"event": "final", "text": "second", "ms": 100}, "EOF"])

    def test_stopping_the_service_cancels_the_live_session(self):
        import signal
        self.started()
        owner = self.request(cmd="start")
        self.host_read()
        self.process.send_signal(signal.SIGTERM)
        self.assertEqual(self.host_read(), {"type": "cancel", "session": 1})
        self.assertEqual(self.client_read(owner), {"event": "cancelled"})
        self.assertEqual(self.process.wait(timeout=5), 0)

    def test_unknown_command_is_refused(self):
        self.started()
        self.assertEqual(self.read_events(self.request(cmd="launch"), 1),
                         [{"ok": False, "error": "unknown command"}, "EOF"])

    def test_exits_quietly_without_the_port(self):
        self.start(port_path=os.path.join(self.runtime.name, "missing"))
        self.assertEqual(self.process.wait(timeout=5), 0)
        self.assertFalse(os.path.exists(self.socket_path))



class FakeDictationBridge:
    """apple-dictation.sock as omarchy-native-dictation-bridge serves it, with
    the test deciding what the Mac says."""

    def __init__(self, path):
        import socket
        import threading
        self.path = path
        self.commands = []
        self.owners = []
        self.live = False
        self.changed = threading.Condition()
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(path)
        self.listener.listen(8)
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while True:
            try:
                connection, _ = self.listener.accept()
            except OSError:
                return
            line = connection.makefile("rb").readline()
            try:
                request = json.loads(line)
            except ValueError:
                connection.close()
                continue
            with self.changed:
                self.commands.append(request)
                if request.get("cmd") == "start":
                    self.live = True
                    self.owners.append(connection)
                elif request.get("cmd") == "ping":
                    connection.sendall((json.dumps({"ok": True, "session": self.live}) + "\n").encode())
                    connection.close()
                else:
                    connection.sendall(b'{"ok":true}\n')
                    connection.close()
                self.changed.notify_all()

    def wait_for(self, predicate, timeout=3.0):
        with self.changed:
            return self.changed.wait_for(lambda: predicate(self), timeout)

    def send(self, owner, **event):
        owner.sendall((json.dumps(event) + "\n").encode())

    def finish(self, owner, **event):
        self.send(owner, **event)
        self.live = False
        owner.close()

    def close(self):
        self.listener.close()
        for owner in self.owners:
            owner.close()


def fake_tools(directory, *names):
    """Programs that only record their arguments, one line per call."""
    for name in names:
        tool = directory / name
        tool.write_text('#!/bin/sh\nprintf \'%s %s\\n\' "${0##*/}" "$*" >>"$TEST_LOG"\n')
        tool.chmod(0o755)


class AppleSpeech(unittest.TestCase):
    """apple-speech, Omarchy's `apple-speech` dictation backend: the bridge's
    socket in, typed text out, and nothing at all when Dictation is off."""

    CLIENT = FILES / "usr/bin/apple-speech"

    def setUp(self):
        self.runtime = tempfile.TemporaryDirectory()
        root = Path(self.runtime.name)
        self.port = root / "port"
        self.port.touch()
        self.socket_path = str(root / "apple-dictation.sock")
        self.bin = root / "bin"
        self.bin.mkdir()
        self.log = root / "log"
        self.config = root / "config"
        fake_tools(self.bin, "wtype", "notify-send")
        self.bridge = None

    def tearDown(self):
        if self.bridge:
            self.bridge.close()
        self.runtime.cleanup()

    def serve(self):
        self.bridge = FakeDictationBridge(self.socket_path)
        return self.bridge

    def run_client(self, *args):
        env = {**os.environ, "XDG_RUNTIME_DIR": self.runtime.name, "OMARCHY_DICTATION_PORT": str(self.port),
               "XDG_CONFIG_HOME": str(self.config), "PATH": f"{self.bin}:{os.environ['PATH']}",
               "TEST_LOG": str(self.log)}
        return subprocess.run([sys.executable, str(self.CLIENT), *args], env=env, capture_output=True, text=True,
                              timeout=10)

    def set_model(self, text):
        setting = self.config / "apple-speech/model"
        setting.parent.mkdir(parents=True, exist_ok=True)
        setting.write_text(text)

    def logged(self, timeout=3.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.log.exists() and self.log.read_text():
                return self.log.read_text().splitlines()
            time.sleep(0.02)
        return []

    def test_start_puts_the_session_on_the_socket_before_returning(self):
        # A quick tap's stop follows start at once: the session must already
        # be live at the bridge when start returns, or stop finds nothing.
        bridge = self.serve()
        result = self.run_client("start")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(bridge.commands[:1], [{"cmd": "start", "model": "dictation"}])

    def test_types_the_final_text(self):
        bridge = self.serve()
        self.assertEqual(self.run_client("start").returncode, 0)
        owner = bridge.owners[0]
        bridge.send(owner, event="recording")
        bridge.send(owner, event="partial", text="Hello")
        bridge.finish(owner, event="final", text="Hello there.", ms=90)
        self.assertEqual(self.logged(), ["wtype -- Hello there."])

    def test_stop_and_cancel_reach_the_bridge(self):
        bridge = self.serve()
        self.assertEqual(self.run_client("stop").returncode, 0)
        self.assertEqual(self.run_client("cancel").returncode, 0)
        self.assertEqual(bridge.commands, [{"cmd": "stop"}, {"cmd": "cancel"}])

    def test_toggle_starts_when_idle_and_stops_a_live_session(self):
        bridge = self.serve()
        self.assertEqual(self.run_client("toggle").returncode, 0)
        self.assertEqual(bridge.commands, [{"cmd": "ping"}, {"cmd": "start", "model": "dictation"}])
        self.assertEqual(self.run_client("toggle").returncode, 0)
        self.assertEqual(bridge.commands[2:], [{"cmd": "ping"}, {"cmd": "stop"}])

    def test_silent_when_dictation_is_off(self):
        # No port: Dictation is off in the launcher. Nothing is shown, the
        # socket is never tried, and stop succeeds as Omarchy requires.
        self.port.unlink()
        bridge = self.serve()
        for command, expected in (("start", 1), ("toggle", 1), ("stop", 0), ("cancel", 0)):
            result = self.run_client(command)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (expected, "", ""), command)
        self.assertEqual(bridge.commands, [])
        self.assertFalse(self.log.exists())

    def test_waits_for_a_bridge_that_is_still_starting(self):
        import threading
        later = threading.Timer(0.3, self.serve)
        later.start()
        result = self.run_client("start")
        later.join()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.bridge.wait_for(lambda b: b.commands))
        self.assertEqual(self.bridge.commands, [{"cmd": "start", "model": "dictation"}])

    def test_says_so_when_dictation_is_on_but_the_bridge_never_answers(self):
        result = self.run_client("start")
        self.assertEqual(result.returncode, 1)
        lines = self.logged()
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].startswith("notify-send "), lines)

    def test_shows_the_macs_error_and_types_nothing(self):
        bridge = self.serve()
        self.run_client("start")
        bridge.finish(bridge.owners[0], event="error",
                      message="Allow microphone access for Try Omarchy in System Settings")
        lines = self.logged()
        self.assertEqual(len(lines), 1)
        self.assertIn("Allow microphone access for Try Omarchy in System Settings", lines[0])
        self.assertTrue(lines[0].startswith("notify-send "))

    def test_a_cancelled_session_is_quiet(self):
        bridge = self.serve()
        self.run_client("start")
        bridge.finish(bridge.owners[0], event="cancelled")
        self.assertEqual(self.logged(timeout=0.5), [])

    def test_starts_with_the_chosen_model(self):
        self.set_model("speech\n")
        bridge = self.serve()
        self.assertEqual(self.run_client("start").returncode, 0)
        self.assertEqual(bridge.commands[:1], [{"cmd": "start", "model": "speech"}])

    def test_an_unknown_model_falls_back_to_dictation(self):
        self.set_model("whisper\n")
        bridge = self.serve()
        self.assertEqual(self.run_client("start").returncode, 0)
        self.assertEqual(bridge.commands[:1], [{"cmd": "start", "model": "dictation"}])

    def test_model_command_shows_and_sets_the_model(self):
        # Works with Dictation off too: it only touches the setting.
        self.port.unlink()
        shown = self.run_client("model")
        self.assertEqual((shown.returncode, shown.stdout), (0, "dictation\n"))
        self.assertEqual(self.run_client("model", "speech").returncode, 0)
        self.assertEqual((self.config / "apple-speech/model").read_text(), "speech\n")
        self.assertEqual(self.run_client("model").stdout, "speech\n")

    def test_model_command_refuses_an_unknown_model(self):
        result = self.run_client("model", "whisper")
        self.assertEqual(result.returncode, 2)
        self.assertIn("speech|dictation", result.stderr)
        self.assertFalse((self.config / "apple-speech/model").exists())

    def test_omarchy_adapter_passes_its_commands_through(self):
        adapter = FILES / "usr/bin/omarchy-dictation-apple-speech"
        self.assertIn('start|stop|toggle) exec apple-speech "$1"', adapter.read_text())
        self.assertTrue(adapter.stat().st_mode & stat.S_IXUSR)


class DictationBackend(unittest.TestCase):
    """Choosing Apple Speech as Omarchy's dictation backend keeps the backend
    it replaced, puts that one back while Dictation is off in the launcher,
    and never undoes a choice the user made since."""

    HELPER = LIB / "dictation-backend"

    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.config = self.root / "config"
        self.selection = self.config / "omarchy/defaults/dictation"
        self.state = self.root / "state/try-omarchy/dictation-backend"
        self.port = self.root / "port"
        self.port.touch()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "log"
        fake_tools(self.bin, "hyprctl", "notify-send")
        # Omarchy's omarchy-dictation-use: stop the old backend, save the new.
        use = self.bin / "omarchy-dictation-use"
        use.write_text('#!/bin/sh\nprintf \'use %s\\n\' "$1" >>"$TEST_LOG"\n'
                       'mkdir -p "$XDG_CONFIG_HOME/omarchy/defaults"\n'
                       'printf \'%s\\n\' "$1" >"$XDG_CONFIG_HOME/omarchy/defaults/dictation.new"\n'
                       'mv -f "$XDG_CONFIG_HOME/omarchy/defaults/dictation.new" '
                       '"$XDG_CONFIG_HOME/omarchy/defaults/dictation"\n')
        use.chmod(0o755)
        self.env = {**os.environ, "HOME": str(self.root), "XDG_CONFIG_HOME": str(self.config),
                    "XDG_STATE_HOME": str(self.root / "state"), "OMARCHY_DICTATION_PORT": str(self.port),
                    "PATH": f"{self.bin}:{os.environ['PATH']}", "TEST_LOG": str(self.log),
                    "TRY_OMARCHY_DICTATION_BACKEND": str(self.HELPER)}

    def select(self, backend):
        self.selection.parent.mkdir(parents=True, exist_ok=True)
        self.selection.write_text(backend + "\n")

    def selected(self):
        return self.selection.read_text().strip() if self.selection.exists() else None

    def helper(self, command):
        result = subprocess.run([sys.executable, str(self.HELPER), command], env=self.env, capture_output=True,
                                text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def dictation_off(self):
        self.port.unlink()

    def dictation_on(self):
        self.port.touch()

    def test_choosing_apple_speech_remembers_the_backend_it_replaces(self):
        self.select("voxtype")
        self.helper("select")
        self.assertEqual(self.selected(), "apple-speech")
        self.assertEqual(json.loads(self.state.read_text())["previous"], "voxtype")
        # Choosing it again keeps the first backend, not apple-speech itself.
        self.helper("select")
        self.assertEqual(json.loads(self.state.read_text())["previous"], "voxtype")

    def test_dictation_off_puts_the_previous_backend_back_and_on_brings_apple_speech_back(self):
        self.select("voxtype")
        self.helper("select")
        self.dictation_off()
        self.assertEqual(self.helper("login"), "changed")
        self.assertEqual(self.selected(), "voxtype")
        self.assertEqual(self.helper("login"), "")  # nothing more to do
        self.dictation_on()
        self.assertEqual(self.helper("login"), "changed")
        self.assertEqual(self.selected(), "apple-speech")
        self.assertEqual(self.helper("login"), "")

    def test_with_nothing_before_it_dictation_off_clears_the_selection(self):
        # No backend left selected: Omarchy binds no dictation keys at all.
        self.helper("select")
        self.dictation_off()
        self.assertEqual(self.helper("login"), "changed")
        self.assertIsNone(self.selected())
        self.dictation_on()
        self.assertEqual(self.helper("login"), "changed")
        self.assertEqual(self.selected(), "apple-speech")

    def test_a_choice_made_while_dictation_was_off_is_kept(self):
        self.select("superwhisper")
        self.helper("select")
        self.dictation_off()
        self.helper("login")
        self.select("voxtype")  # the user picks a backend meanwhile
        self.dictation_on()
        self.assertEqual(self.helper("login"), "")
        self.assertEqual(self.selected(), "voxtype")
        self.assertFalse(self.state.exists())

    def test_choosing_the_restored_backend_again_is_kept(self):
        self.select("voxtype")
        self.helper("select")
        self.dictation_off()
        self.helper("login")
        subprocess.run([str(self.bin / "omarchy-dictation-use"), "voxtype"], env=self.env, check=True)
        self.dictation_on()
        self.assertEqual(self.helper("login"), "")
        self.assertEqual(self.selected(), "voxtype")
        self.assertFalse(self.state.exists())

    def test_switching_away_from_apple_speech_forgets_it(self):
        self.select("voxtype")
        self.helper("select")
        self.select("voxtype")  # Omarchy's own installer switched back
        self.assertEqual(self.helper("login"), "")
        self.assertFalse(self.state.exists())
        self.dictation_off()
        self.helper("login")
        self.assertEqual(self.selected(), "voxtype")

    def test_does_nothing_unless_apple_speech_was_chosen(self):
        self.select("voxtype")
        self.dictation_off()
        self.assertEqual(self.helper("login"), "")
        self.assertEqual(self.selected(), "voxtype")
        self.assertEqual(self.calls(), [])
        self.assertFalse(self.state.exists())

    def test_removing_apple_speech_puts_the_previous_backend_back(self):
        self.select("voxtype")
        self.helper("select")
        self.helper("remove")
        self.assertEqual(self.selected(), "voxtype")
        self.assertFalse(self.state.exists())

    def test_removing_after_the_user_moved_on_leaves_their_choice(self):
        self.select("voxtype")
        self.helper("select")
        self.select("superwhisper")
        self.helper("remove")
        self.assertEqual(self.selected(), "superwhisper")
        self.assertFalse(self.state.exists())

    def installer(self, name):
        return subprocess.run(["/bin/bash", str(FILES / "usr/bin" / name)], env=self.env, capture_output=True,
                              text=True, timeout=10)

    def test_installer_is_silent_and_changes_nothing_when_dictation_is_off(self):
        self.select("voxtype")
        self.dictation_off()
        result = self.installer("omarchy-install-dictation-apple-speech")
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))
        self.assertEqual(self.selected(), "voxtype")
        self.assertEqual(self.calls(), [])

    def test_installer_selects_apple_speech_and_reloads_the_keys(self):
        self.select("voxtype")
        result = self.installer("omarchy-install-dictation-apple-speech")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.selected(), "apple-speech")
        calls = self.calls()
        self.assertIn("use apple-speech", calls)
        self.assertIn("hyprctl reload", calls)
        self.assertTrue(any(line.startswith("notify-send ") for line in calls), calls)

    def test_remover_restores_the_previous_backend(self):
        self.select("voxtype")
        self.installer("omarchy-install-dictation-apple-speech")
        result = self.installer("omarchy-remove-dictation-apple-speech")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.selected(), "voxtype")
        self.assertFalse(self.state.exists())

    def test_user_setup_swaps_at_login_and_reloads_hyprland(self):
        self.select("voxtype")
        self.helper("select")
        self.dictation_off()
        env = {**self.env, "TRY_OMARCHY_MENU_ENTRIES": "/usr/bin/true", "TRY_OMARCHY_IDLE_DEFAULTS": "/usr/bin/true",
               "TRY_OMARCHY_BACKGROUNDS": str(self.root / "none"), "HYPRLAND_INSTANCE_SIGNATURE": "test"}
        # The loader is already in place, so only the swap can ask for a reload.
        loader = self.root / "state/omarchy/toggles/hypr/zz-try-omarchy.lua"
        run(LIB / "user-setup", env=env)
        self.assertTrue(loader.is_file())
        self.log.unlink()
        self.dictation_on()
        run(LIB / "user-setup", "--reload", env=env)
        self.assertEqual(self.selected(), "apple-speech")
        self.assertIn("hyprctl reload", self.calls())
        self.log.unlink()
        run(LIB / "user-setup", "--reload", env=env)
        self.assertNotIn("hyprctl reload", self.calls())

if __name__ == "__main__":
    unittest.main()
