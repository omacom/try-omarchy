import importlib.util
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
        (payload / "omarchy-menu.jsonc").write_bytes(
            (GUEST / "native-overlay/etc/skel" / installer.MENU).read_bytes())
        return payload

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
            payload = Path(directory) / "payload"
            payload.mkdir()
            for name, (relative, _) in installer.FILES.items():
                (payload / name).write_bytes((GUEST / "native-overlay" / relative).read_bytes())
            (payload / "omarchy-menu.jsonc").write_bytes(
                (GUEST / "native-overlay/etc/skel" / installer.MENU).read_bytes())
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
