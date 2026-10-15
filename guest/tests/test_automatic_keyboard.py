import base64
import json
import os
from pathlib import Path
import tempfile
import unittest

import test_settings_install as support
from test_boot_components import users


class AutomaticKeyboardTests(unittest.TestCase):
    def prepare(self, directory):
        payload = support.SettingsInstallTests().make_payload(directory)
        root = Path(directory) / 'root'
        home = root / 'home/owner'
        input_file = home / '.config/hypr/input.lua'
        input_file.parent.mkdir(parents=True)
        input_file.write_text('hl.config({input = {kb_layout = "fr", kb_options = "caps:escape"}})\n')
        input_file.chmod(0o600)
        return payload, root, home, input_file

    def test_skip_still_installs_hardware_support_without_any_ime(self):
        for geometry in ('ansi', 'iso', 'jis'):
            with self.subTest(geometry=geometry), tempfile.TemporaryDirectory() as directory:
                payload, root, home, input_file = self.prepare(directory)
                original = input_file.read_bytes()
                support.fixes.migrate(payload, root, False, f'tryomarchy.keyboard={geometry}')
                self.assertTrue(support.installer.install_system(payload, root))
                support.installer.install_user(payload, home, keyboard=True)
                self.assertTrue(input_file.read_bytes().startswith(original))
                self.assertEqual(1, input_file.read_text().count('apple-keyboard-input.lua'))
                self.assertEqual(0o600, input_file.stat().st_mode & 0o777)
                self.assertFalse((home / '.config/fcitx5').exists())
                self.assertFalse((root / 'usr/bin/fcitx5').exists())
                inode = input_file.stat().st_ino
                support.installer.install_system(payload, root)
                support.installer.install_user(payload, home, keyboard=True)
                self.assertEqual(inode, input_file.stat().st_ino)

    def test_explicit_models_and_symlinks_are_preserved(self):
        for custom in ('model', 'symlink'):
            with self.subTest(custom=custom), tempfile.TemporaryDirectory() as directory:
                payload, root, home, input_file = self.prepare(directory)
                support.installer.install_system(payload, root)
                if custom == 'model':
                    input_file.write_text('hl.config({input = {kb_model = "personal"}})\n')
                    kept = input_file
                else:
                    kept = home / 'keep'
                    input_file.rename(kept)
                    input_file.symlink_to(kept)
                original = kept.read_bytes()
                support.installer.install_user(payload, home, keyboard=True)
                self.assertEqual(original, kept.read_bytes())

    def test_unknown_or_unsafe_system_overlay_is_not_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, root, _, _ = self.prepare(directory)
            overlay = root / 'usr/share/try-omarchy/apple-keyboard-input.lua'
            overlay.parent.mkdir(parents=True)
            overlay.write_text('-- custom hardware mapping\n')
            self.assertFalse(support.installer.install_keyboard_system(payload, root))
            self.assertEqual('-- custom hardware mapping\n', overlay.read_text())
            kept = root / 'kept'
            overlay.rename(kept)
            overlay.symlink_to(kept)
            self.assertFalse(support.installer.install_keyboard_system(payload, root))
            self.assertEqual('-- custom hardware mapping\n', kept.read_text())

    def test_revision_one_journal_is_recovered_before_automatic_input_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, root, home, input_file = self.prepare(directory)
            fixes = users.transaction(payload)
            uid = os.getuid()
            original = fixes.snapshot(input_file, home, uid)
            after = {**original, 'data': base64.b64encode(b'-- interrupted migration\n').decode()}
            change = {'path': '.config/hypr/input.lua', 'before': original, 'after': after}
            journal = fixes.journal_path(home, uid)
            fixes.write_file(journal, {**original, 'mode': 0o600,
                'data': base64.b64encode(json.dumps({'changes': [change], 'runtime': {}}).encode()).decode()}, home, uid)
            fixes.write_file(input_file, after, home, uid)
            support.installer.install_system(payload, root)
            support.installer.install_user(payload, home, keyboard=True)
            self.assertTrue(input_file.read_bytes().startswith(base64.b64decode(original['data'])))
            self.assertIn('apple-keyboard-input.lua', input_file.read_text())
            self.assertFalse(journal.exists())


if __name__ == '__main__':
    unittest.main()
