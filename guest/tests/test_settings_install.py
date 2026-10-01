import importlib.util
import hashlib
import json
from pathlib import Path
import tempfile
import unittest


GUEST = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("settings_install", GUEST / "scripts/install-settings-integration.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class SettingsInstallTests(unittest.TestCase):
    def make_payload(self, directory):
        payload = Path(directory) / "payload"
        payload.mkdir()
        for name, (relative, _) in installer.FILES.items():
            (payload / name).write_bytes((GUEST / "native-overlay" / relative).read_bytes())
        for name, relative in installer.NATIVE_FIX_FILES.items():
            (payload / name).write_bytes((GUEST / "native-overlay" / relative).read_bytes())
        (payload / "omarchy-menu.jsonc").write_bytes(
            (GUEST / "native-overlay/etc/skel" / installer.MENU).read_bytes())
        return payload

    def seed_legacy_native_files(self, root):
        fixtures = {
            "omarchy-native-clipboard-bridge": "native-clipboard-before-drain",
            "omarchy-screensaver": "native-screensaver-before-fit",
        }
        for name, fixture in fixtures.items():
            contents = (GUEST / "tests/fixtures" / fixture).read_bytes()
            self.assertEqual(installer.PREVIOUS_NATIVE_HASHES[name], hashlib.sha256(contents).hexdigest())
            path = root / installer.NATIVE_FIX_FILES[name]
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(contents)
            path.chmod(0o755)

    def test_stock_retained_vm_receives_fixes_and_repeat_boot_does_not_rewrite(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "root"
            payload = self.make_payload(directory)
            self.seed_legacy_native_files(root)
            installer.install_system(payload, root)
            inodes = {}
            for name, relative in installer.NATIVE_FIX_FILES.items():
                path = root / relative
                self.assertEqual((payload / name).read_bytes(), path.read_bytes())
                self.assertEqual(0o755, path.stat().st_mode & 0o777)
                inodes[name] = path.stat().st_ino
            installer.install_system(payload, root)
            for name, relative in installer.NATIVE_FIX_FILES.items():
                self.assertEqual(inodes[name], (root / relative).stat().st_ino)

    def test_custom_scripts_and_absent_integrations_are_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "root"
            payload = self.make_payload(directory)
            installer.install_system(payload, root)
            for relative in installer.NATIVE_FIX_FILES.values():
                self.assertFalse((root / relative).exists())
            self.seed_legacy_native_files(root)
            for name in installer.PREVIOUS_NATIVE_HASHES:
                path = root / installer.NATIVE_FIX_FILES[name]
                path.write_text("#!/bin/sh\necho my custom behavior\n")
            installer.install_system(payload, root)
            for name in installer.PREVIOUS_NATIVE_HASHES:
                self.assertIn("my custom behavior", (root / installer.NATIVE_FIX_FILES[name]).read_text())
            self.assertFalse((root / installer.NATIVE_FIX_FILES["omarchy-native-screensaver-text"]).exists())

    def test_custom_or_symlinked_dependency_prevents_partial_screensaver_update(self):
        for use_symlink in (False, True):
            with self.subTest(symlink=use_symlink), tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / "root"
                payload = self.make_payload(directory)
                self.seed_legacy_native_files(root)
                screensaver = root / installer.NATIVE_FIX_FILES["omarchy-screensaver"]
                previous = screensaver.read_bytes()
                helper = root / installer.NATIVE_FIX_FILES["omarchy-native-cursor-restore"]
                helper.parent.mkdir(parents=True, exist_ok=True)
                if use_symlink:
                    target = root / "keep"
                    target.write_bytes((payload / "omarchy-native-cursor-restore").read_bytes())
                    helper.symlink_to(target)
                else:
                    helper.write_text("my custom cursor behavior")
                installer.install_system(payload, root)
                self.assertEqual(previous, screensaver.read_bytes())
                self.assertFalse((root / installer.NATIVE_FIX_FILES["omarchy-native-screensaver-text"]).exists())
                self.assertEqual(use_symlink, helper.is_symlink())
                clipboard = root / installer.NATIVE_FIX_FILES["omarchy-native-clipboard-bridge"]
                self.assertEqual((payload / clipboard.name).read_bytes(), clipboard.read_bytes())

    def test_one_branded_search_entry_for_default_and_custom_menus(self):
        with tempfile.TemporaryDirectory() as directory:
            payload = self.make_payload(directory)
            home = Path(directory) / "home"
            installer.install_user(payload, home)
            menu = home / installer.MENU
            desktop = home / installer.DESKTOP
            entry = installer.menu_entries(menu.read_text())["setup.try-omarchy"]
            self.assertEqual("", entry["icon"])
            self.assertEqual("omarchy", entry["iconFont"])
            self.assertIn("NoDisplay=true", desktop.read_text())
            original_stat = desktop.stat()
            installer.install_user(payload, home)
            self.assertEqual(original_stat.st_ino, desktop.stat().st_ino)

            custom = '// My menu\n{"personal": {"label": "Personal"}}\n'
            menu.write_text(custom)
            installer.install_user(payload, home)
            self.assertEqual(custom, menu.read_text())
            self.assertIn("NoDisplay=false", desktop.read_text())
            self.assertIn("Icon=/usr/share/pixmaps/omarchy.png", desktop.read_text())

            # Restoring Setup must hide the fallback again on the next boot.
            menu.write_bytes((payload / "omarchy-menu.jsonc").read_bytes())
            installer.install_user(payload, home)
            self.assertIn("NoDisplay=true", desktop.read_text())

    def test_legacy_entry_gets_logo_without_replacing_other_menu_content(self):
        with tempfile.TemporaryDirectory() as directory:
            payload = self.make_payload(directory)
            home = Path(directory) / "home"
            menu = home / installer.MENU
            menu.parent.mkdir(parents=True)
            suffix = ',\n  // Keep my action.\n  "personal": {"action": "my-command"},\n}\n'
            menu.write_text('{\n  "setup.try-omarchy": ' + json.dumps(installer.LEGACY_ENTRY) + suffix)
            menu.chmod(0o600)
            installer.install_user(payload, home)
            self.assertTrue(menu.read_text().endswith(suffix))
            self.assertEqual(0o600, menu.stat().st_mode & 0o777)
            self.assertEqual("omarchy", installer.menu_entries(menu.read_text())["setup.try-omarchy"]["iconFont"])
            self.assertIn("NoDisplay=true", (home / installer.DESKTOP).read_text())
            original = menu.read_bytes()
            installer.install_user(payload, home)
            self.assertEqual(original, menu.read_bytes())

    def test_custom_settings_entry_and_desktop_are_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            payload = self.make_payload(directory)
            home = Path(directory) / "home"
            menu = home / installer.MENU
            menu.parent.mkdir(parents=True)
            custom = '{"items": {"setup.mine": {"label": "My Settings", "action": "omarchy-native-settings"}}}\n'
            menu.write_text(custom)
            installer.install_user(payload, home)
            self.assertEqual(custom, menu.read_text())
            desktop = home / installer.DESKTOP
            self.assertIn("NoDisplay=true", desktop.read_text())
            desktop.write_text("my custom desktop entry")
            installer.install_user(payload, home)
            self.assertEqual("my custom desktop entry", desktop.read_text())

    def test_installs_updates_and_preserves_custom_menu(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "root"
            payload = self.make_payload(directory)
            installer.install_system(payload, root)
            command = root / "usr/local/bin/omarchy-native-settings"
            original_stat = command.stat()
            installer.install_system(payload, root)
            self.assertEqual(original_stat.st_ino, command.stat().st_ino)
            self.assertEqual(0o755, command.stat().st_mode & 0o777)
            (payload / "omarchy-native-settings").write_text("updated helper")
            installer.install_system(payload, root)
            self.assertEqual("updated helper", command.read_text())
            home = root / "home/person"
            installer.install_menu(payload / "omarchy-menu.jsonc", home)
            menu = home / installer.MENU
            self.assertIn("setup.try-omarchy", menu.read_text())
            menu.write_text('// My custom menu\n{"mine": {}}\n')
            installer.install_menu(payload / "omarchy-menu.jsonc", home)
            self.assertEqual('// My custom menu\n{"mine": {}}\n', menu.read_text())

    def test_existing_menu_symlink_is_not_followed(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            target = home / "keep"
            target.write_text("keep this")
            menu = home / installer.MENU
            menu.parent.mkdir(parents=True)
            menu.symlink_to(target)
            installer.install_menu(target, home)
            self.assertTrue(menu.is_symlink())
            self.assertEqual("keep this", target.read_text())
