#!/usr/bin/env python3
"""Contracts between the try-omarchy package and the Omarchy it runs on.

The package changes Omarchy only from outside: menu rows by key, commands by
name, unit drop-ins by unit name, the sleep switch and the Hyprland toggles
directory by path. These tests read the current Omarchy (omarchy-dev and
omarchy-settings-dev, as the factory installs them) and fail when upstream
renames or drops one of those, before a user finds the row or switch gone.

OMARCHY_UPSTREAM_ROOT names a root holding those packages' files: an unpacked
copy (guest/tests/fetch-upstream.sh) or / in a running guest. A full system
root (one with usr/lib/os-release) also checks the units and desktop entries
of the other packages the drop-ins name. Without it, the tests are skipped.
"""

import json
import os
from pathlib import Path
import re
import unittest

PACKAGE = Path(__file__).resolve().parents[1] / "try-omarchy"
FILES = PACKAGE / "files"
ROOT = Path(os.environ["OMARCHY_UPSTREAM_ROOT"]) if os.environ.get("OMARCHY_UPSTREAM_ROOT") else None
OMARCHY = ROOT / "usr/share/omarchy" if ROOT else None

# Names the package uses that are not upstream commands: its own programs and
# Omarchy's package names.
OWN_PREFIXES = ("omarchy-native-",)
NOT_COMMANDS = {"omarchy-dev", "omarchy-settings-dev"}


def strip_jsonc(text):
    """Omarchy's menu parser: whole-line comments and trailing commas go."""
    lines = [line for line in text.splitlines() if not line.lstrip().startswith("//")]
    return re.sub(r",(\s*[}\]])", r"\1", "\n".join(lines))


def menu_rows(text):
    return json.loads(strip_jsonc(text))


def menu_entries():
    namespace = {"__name__": "menu_entries"}
    exec(compile((FILES / "usr/lib/try-omarchy/menu-entries").read_text(), "menu-entries", "exec"), namespace)
    return namespace


@unittest.skipUnless(ROOT, "OMARCHY_UPSTREAM_ROOT is not set")
class UpstreamContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.upstream_menu = menu_rows((OMARCHY / "default/omarchy/omarchy-menu.jsonc").read_text())
        cls.entries = menu_entries()
        # A row of our own builds without Omarchy's rows; a change to one of
        # Omarchy's rows builds only from that row.
        cls.own = {key: build({}) for key, _, build in cls.entries["ROWS"] if build({}) is not None}
        cls.changed = {key: build for key, _, build in cls.entries["ROWS"] if key not in cls.own}
        cls.full_system = (ROOT / "usr/lib/os-release").is_file()

    def test_menu_extension_is_read_from_the_path_we_write(self):
        menu = (OMARCHY / "shell/plugins/menu/Menu.qml").read_text()
        self.assertIn('"/.config/omarchy/extensions/omarchy-menu.jsonc"', menu)

    def test_every_row_we_change_still_exists_upstream(self):
        # A change to a row Omarchy dropped or renamed silently stops applying
        # (menu-entries skips it), e.g. the VM would show Direct Boot again.
        for key, build in self.changed.items():
            self.assertTrue(build(self.upstream_menu), f"{key} is gone from Omarchy's menu; try-omarchy's change no longer applies")

    def test_every_change_still_changes_omarchys_row(self):
        # A change can match nothing in a reworded row, e.g. a condition
        # without the laptop check we widen.
        for key, build in self.changed.items():
            self.assertNotEqual(build(self.upstream_menu), self.upstream_menu.get(key), f"{key}: try-omarchy's change no longer changes Omarchy's row")

    def test_changed_rows_keep_omarchys_label_and_action(self):
        # Omarchy's merge replaces a row whole: a change must carry the rest.
        for key, build in self.changed.items():
            upstream = self.upstream_menu.get(key, {})
            entry = build(self.upstream_menu) or {}
            self.assertEqual(entry.get("label"), upstream.get("label"), key)
            self.assertEqual(bool(entry.get("action")), bool(upstream.get("action")), key)

    def test_added_rows_have_their_parent_menu(self):
        for key in self.own:
            parent = key.rsplit(".", 1)[0]
            self.assertTrue(parent in self.upstream_menu, f"{key}: no {parent} menu upstream")

    def test_dictation_backends_still_plug_in_by_name(self):
        # apple-speech is an Omarchy dictation backend from outside: the
        # selection file, omarchy-dictation-<backend> and its installer, and
        # keys bound only while the backend's own program is installed (which
        # is why dictation-backend swaps it out while Dictation is off).
        dispatcher = (ROOT / "usr/bin/omarchy-dictation").read_text()
        self.assertIn('adapter="omarchy-dictation-$backend"', dispatcher)
        selector = (ROOT / "usr/bin/omarchy-default-dictation").read_text()
        self.assertIn("/omarchy/defaults/dictation", selector)
        self.assertIn('installer="omarchy-install-dictation-$backend"', selector)
        self.assertIn("/omarchy/defaults/dictation", (ROOT / "usr/bin/omarchy-dictation-use").read_text())
        bindings = (OMARCHY / "default/hypr/bindings/dictation.lua").read_text()
        self.assertIn("not o.cmd_missing(backend)", bindings)
        self.assertIn('"omarchy-dictation start"', bindings)

    def test_timezone_row_falls_back_to_upstreams_action(self):
        upstream = self.upstream_menu.get("update.timezone", {}).get("action", "")
        self.assertIn(f"exec {upstream}", self.entries["TIMEZONE_ACTION"])

    def test_every_omarchy_command_we_call_exists(self):
        # Omarchy's bin directory links each command to /usr/bin; a link whose
        # command is gone does not count.
        commands = {path.name for directory in ("usr/bin", "usr/share/omarchy/bin")
                    if (ROOT / directory).is_dir() for path in (ROOT / directory).iterdir()
                    if not path.is_symlink() or (ROOT / "usr/bin" / path.name).exists()}
        missing = {}
        for path in [*FILES.rglob("*"), PACKAGE / "try-omarchy.install"]:
            if not path.is_file() or "__pycache__" in path.parts:
                continue
            for line in path.read_text(errors="ignore").splitlines():
                if line.lstrip().startswith("#"):
                    continue
                for match in re.finditer(r"(?<![\w./-])omarchy-[a-z0-9][a-z0-9-]*[a-z0-9](?![\w.-])", line):
                    name = match.group(0)
                    if name in NOT_COMMANDS or name.startswith(OWN_PREFIXES) or name in commands:
                        continue
                    if (FILES / "usr/bin" / name).exists():
                        continue
                    missing.setdefault(name, set()).add(str(path.relative_to(PACKAGE)))
        self.assertEqual(missing, {}, "commands the package calls that Omarchy no longer ships")

    def test_drop_ins_name_units_that_exist(self):
        unit_dirs = ("usr/lib/systemd/system", "usr/lib/systemd/user",
                     "usr/share/omarchy/install/provisioning", "usr/share/omarchy/config/systemd/user")
        shipped = {path.name for directory in unit_dirs if (ROOT / directory).is_dir()
                   for path in (ROOT / directory).iterdir()}
        for drop_in in FILES.glob("usr/lib/systemd/*/*.d"):
            unit = drop_in.name[:-2]
            if unit.startswith("omarchy-") or self.full_system:
                self.assertTrue(unit in shipped, f"{drop_in.relative_to(FILES)} extends a unit nothing ships")

    def test_bar_clock_still_answers_the_refresh_we_send(self):
        # clock-refresh redraws the bar after a time zone change or a clock
        # step; without the target the bar can show the old time for a minute.
        refresh = (FILES / "usr/lib/try-omarchy/clock-refresh").read_text()
        self.assertIn('"omarchy-shell", "-q", "omarchy.clock", "refresh"', refresh)
        targets = [block for path in (OMARCHY / "shell").rglob("*.qml")
                   for block in re.findall(r"ShellIpc \{(.*?)\n  \}", path.read_text(), re.S)
                   if re.search(r'target: "omarchy\.clock"', block)]
        self.assertTrue(any(re.search(r"function refresh\(\)", block) for block in targets),
                        "Omarchy's shell no longer answers omarchy.clock refresh")

    def test_sleep_switch_is_the_file_omarchy_checks(self):
        script = (ROOT / "usr/bin/omarchy-sleep-disabled").read_text()
        self.assertIn("/etc/systemd/sleep.conf.d}/omarchy-sleep-disabled.conf", script)
        self.assertTrue((FILES / "etc/systemd/sleep.conf.d/omarchy-sleep-disabled.conf").is_file())

    def test_bar_reads_the_camera_cutouts_host_config_writes(self):
        # host-config writes {"panels": [{connector, width, height, top}]} for
        # QEMU's Virtual-1, linked from the platform root Omarchy reads.
        bar = (OMARCHY / "shell/plugins/bar/Bar.qml").read_text()
        model = (OMARCHY / "shell/plugins/bar/BarModel.js").read_text()
        self.assertIn('path: "/usr/share/omarchy-platform/display-cutouts.json"', bar)
        self.assertIn("watchChanges: true", bar[bar.index("display-cutouts.json") - 400:])
        self.assertIn("parsed.panels", model)
        for field in ("panel.connector", "panel.width", "panel.height", "panel.top"):
            self.assertIn(field, model)
        self.assertIn("name.indexOf(panel.connector) !== 0", model)
        self.assertIn("/run/try-omarchy/display-cutouts.json", (PACKAGE / "PKGBUILD").read_text())

    def test_hyprland_loads_every_lua_file_in_the_toggles_directory(self):
        toggles = (OMARCHY / "default/hypr/toggles.lua").read_text()
        self.assertIn('"/omarchy/toggles/hypr"', toggles)
        self.assertIn("require_all.files(toggles_dir", toggles)
        self.assertIn("omarchy/toggles/hypr", (FILES / "usr/lib/try-omarchy/user-setup").read_text())

    def test_setup_form_preselects_the_time_zone_default(self):
        # setup-form-defaults sets the default in the environment, which the
        # form-defaults file doesn't override, to Same as macOS, a row the
        # timedatectl stand-in lists.
        form = (OMARCHY / "install/provisioning/setup-form.sh").read_text()
        self.assertIn(': "${OMARCHY_FORM_TIMEZONE_DEFAULT:=', form)
        prompt = form[form.index("omarchy_prompt_timezone() {"):]
        prompt = prompt[:prompt.index("\n}\n")]
        self.assertIn("guess=${OMARCHY_FORM_TIMEZONE_DEFAULT:-}", prompt)
        self.assertRegex(prompt, r'timedatectl list-timezones \| gum choose\b[^\n]*--selected "\$guess"')
        self.assertIn("OMARCHY_FORM_TIMEZONE_DEFAULT=", (FILES / "usr/lib/try-omarchy/setup-form-defaults").read_text())

    def test_provisioning_service_and_its_autologin_cleanup_keep_their_names(self):
        provision = (ROOT / "usr/bin/omarchy-provision-owner").read_text()
        self.assertIn("local unit=omarchy-provision-autologin-once.service", provision)
        self.assertTrue((OMARCHY / "install/provisioning/omarchy-provision-owner.service").is_file())

    def test_fcitx5_configuration_we_read_exists(self):
        self.assertTrue((OMARCHY / "config/fcitx5/config").is_file())

    @unittest.skipUnless(ROOT and (ROOT / "usr/lib/os-release").is_file(), "needs a full system root")
    def test_ghostty_entry_matches_upstreams_apart_from_exec(self):
        def without_exec(path):
            return [line for line in path.read_text().splitlines() if not line.startswith("Exec=")]
        upstream = ROOT / "usr/share/applications/com.mitchellh.ghostty.desktop"
        ours = FILES / "usr/share/try-omarchy/xdg/applications/com.mitchellh.ghostty.desktop"
        self.assertEqual(without_exec(ours), without_exec(upstream))


if __name__ == "__main__":
    unittest.main()
