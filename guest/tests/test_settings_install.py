import importlib.util
from pathlib import Path
import tempfile
import unittest


GUEST = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("settings_install", GUEST / "scripts/install-settings-integration.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class SettingsInstallTests(unittest.TestCase):
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
