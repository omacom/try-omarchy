import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import test_boot_components as support
import test_1password_desktop_entry as desktop_support


fixes = support.fixes
extras = support.extras
GUEST = support.support.GUEST
COMPONENT = 'onepassword-installer'
INSTALLER = 'omarchy-install-service-1password'
TARGET = 'usr/bin/' + INSTALLER
LEGACY = GUEST / 'tests/fixtures/1password-installer-before-desktop-rename'
CURRENT = GUEST / 'migrations' / INSTALLER


class OnePasswordMigrationTests(unittest.TestCase):
    def prepare(self, directory, manual_workaround=False):
        payload, root = support.BootComponentTests().prepare(directory)
        data = LEGACY.read_bytes()
        self.assertEqual('ce404a13daf7cb08fab413ae0100786fc64abe6aefc403147114e6208c58b5c4',
                         hashlib.sha256(data).hexdigest())
        if manual_workaround:
            data = data.replace(b'/usr/share/applications/1password.desktop',
                                b'/usr/share/applications/com.onepassword.OnePassword.desktop')
        preimages = json.loads((payload / 'preimages.json').read_text())
        self.assertIn(hashlib.sha256(data).hexdigest(), preimages[TARGET])
        target = root / TARGET
        target.write_bytes(data)
        target.chmod(0o755)
        # An interrupted optional install may already have application/vault
        # state. Updating its command must not install or configure anything.
        preserved = {
            'opt/1Password/1password': b'existing application',
            'usr/local/bin/1password': b'existing application wrapper',
            'usr/share/applications/com.onepassword.OnePassword.desktop': b'existing desktop entry',
            'home/user/.config/1Password/settings/settings.json': b'existing account settings',
            'home/user/.config/1Password/1password.sqlite': b'existing vault data',
            'etc/pam.d/sudo': b'existing sudo policy',
            'var/lib/try-omarchy/native-authentication.json': b'{"enrollment":"keep"}',
        }
        for relative, contents in preserved.items():
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(contents)
            path.chmod(0o600)
        return payload, root, {
            relative: fixes.snapshot(root / relative, root, os.getuid())
            for relative in preserved
        }

    def assert_preserved(self, root, before):
        for relative, original in before.items():
            self.assertEqual(original, fixes.snapshot(root / relative, root, os.getuid()))
        self.assertFalse((root / 'usr/bin/op').exists())
        self.assertFalse((root / 'usr/local/lib/try-omarchy/onepassword-touch-id-agent').exists())
        self.assertFalse((root / 'usr/lib/systemd/system/try-omarchy-onepassword-touch-id@.service').exists())

    def test_update_repairs_stock_and_manual_workaround_without_running_installer(self):
        for manual_workaround in (False, True):
            with self.subTest(manual_workaround=manual_workaround), tempfile.TemporaryDirectory() as directory:
                payload, root, preserved = self.prepare(directory, manual_workaround)
                with patch('subprocess.run', side_effect=AssertionError('Migration executed a command')):
                    result = fixes.migrate(payload, root, True, '')
                self.assertEqual('complete', result['state'])
                self.assertEqual('applied', result['components'][COMPONENT])
                self.assertEqual('current', result['components']['onepassword'])
                self.assertEqual('preserved', result['components']['touch-id'])
                target = root / TARGET
                self.assertEqual((payload / INSTALLER).read_bytes(), target.read_bytes())
                self.assertEqual(0o755, target.stat().st_mode & 0o777)
                self.assert_preserved(root, preserved)
                inode = target.stat().st_ino
                result = fixes.migrate(payload, root, True, '')
                self.assertEqual('current', result['components'][COMPONENT])
                self.assertEqual(inode, target.stat().st_ino)
                self.assert_preserved(root, preserved)

    def test_skip_reports_pending_and_keeps_original_command(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, root, preserved = self.prepare(directory)
            before = fixes.snapshot(root / TARGET, root, os.getuid())
            result = fixes.migrate(payload, root, False, '')
            self.assertEqual('skipped', result['state'])
            self.assertEqual('pending', result['components'][COMPONENT])
            self.assertEqual(before, fixes.snapshot(root / TARGET, root, os.getuid()))
            self.assert_preserved(root, preserved)

    def test_migrated_installer_continues_with_renamed_desktop_entry(self):
        with tempfile.TemporaryDirectory(prefix='1password migration ') as directory:
            payload, root, preserved = self.prepare(directory)
            result = fixes.migrate(payload, root, True, '')
            self.assertEqual('applied', result['components'][COMPONENT])
            desktop_dir = Path(directory) / 'desktop'
            desktop_dir.mkdir()
            desktop = desktop_dir / desktop_support.CURRENT
            desktop.write_text('Exec=/opt/1Password/1password %U\n')
            result = desktop_support.OnePasswordDesktopEntryTests().run_installer_tail(
                desktop_dir, installer_text=(root / TARGET).read_text())
            self.assertEqual(0, result.returncode, result.stderr)
            self.assertEqual('Exec=/usr/local/bin/1password %U\n', desktop.read_text())
            self.assertIn('1password-cli', (desktop_dir / 'cli-installed').read_text())
            self.assertIn('continued', result.stdout)
            self.assert_preserved(root, preserved)

    def test_missing_command_is_unavailable_and_is_not_created(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, root, preserved = self.prepare(directory)
            (root / TARGET).unlink()
            result = fixes.migrate(payload, root, True, '')
            self.assertEqual('unavailable', result['components'][COMPONENT])
            self.assertFalse((root / TARGET).exists())
            self.assert_preserved(root, preserved)

    def test_custom_symlinked_or_unprotected_command_is_preserved(self):
        for kind in ('custom', 'symlink', 'writable'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                payload, root, preserved = self.prepare(directory)
                target = root / TARGET
                if kind == 'custom':
                    target.write_bytes(target.read_bytes() + b'\n# local customization\n')
                elif kind == 'symlink':
                    target.unlink()
                    target.symlink_to(root / 'opt/1Password/1password')
                else:
                    target.chmod(0o777)
                before, mode = target.read_bytes(), target.lstat().st_mode
                result = fixes.migrate(payload, root, True, '')
                self.assertEqual('preserved', result['components'][COMPONENT])
                self.assertEqual(before, target.read_bytes())
                self.assertEqual(mode, target.lstat().st_mode)
                self.assertEqual(kind == 'symlink', target.is_symlink())
                self.assert_preserved(root, preserved)

    def test_failed_write_or_interruption_restores_command_including_on_skip(self):
        class Interrupted(BaseException):
            pass

        for interrupt in (False, True):
            with self.subTest(interrupt=interrupt), tempfile.TemporaryDirectory() as directory:
                payload, root, preserved = self.prepare(directory)
                target = root / TARGET
                original = fixes.snapshot(target, root, os.getuid())
                writer, failed = fixes.write_file, False

                def failing_write(path, value, *args):
                    nonlocal failed
                    result = writer(path, value, *args)
                    if path == target and not failed:
                        failed = True
                        if interrupt:
                            raise Interrupted()
                        raise OSError('simulated failure after installer replacement')
                    return result

                with patch.object(fixes, 'write_file', side_effect=failing_write):
                    if interrupt:
                        with self.assertRaises(Interrupted):
                            fixes.migrate(payload, root, True, '')
                    else:
                        result = fixes.migrate(payload, root, True, '')
                        self.assertEqual('failed', result['state'])
                self.assertTrue(failed)
                if interrupt:
                    self.assertNotEqual(original, fixes.snapshot(target, root, os.getuid()))
                    result = fixes.migrate(payload, root, False, '')
                    self.assertEqual('skipped', result['state'])
                    self.assertEqual('pending', result['components'][COMPONENT])
                self.assertEqual(original, fixes.snapshot(target, root, os.getuid()))
                self.assert_preserved(root, preserved)

    def test_payload_matches_reviewed_installer_and_is_bound_to_consent(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, root, preserved = self.prepare(directory)
            spec = json.loads((GUEST / 'spec.json').read_text())
            backport = next(item for item in spec['authenticity']['backports']
                            if item['id'] == '1password-arm64-installer')
            target = next(item for item in backport['targets']
                          if item['path'] == 'bin/' + INSTALLER)
            packaged = payload / INSTALLER
            self.assertEqual(target['afterSha256'], hashlib.sha256(packaged.read_bytes()).hexdigest())
            manifest = fixes.bundle_manifest(payload)
            self.assertEqual(target['afterSha256'], manifest['files'][INSTALLER])
            packaged.write_bytes(packaged.read_bytes() + b'\n# altered payload\n')
            with self.assertRaisesRegex(RuntimeError, 'payload verification'):
                fixes.migrate(payload, root, True, '')
            self.assertEqual(LEGACY.read_bytes(), (root / TARGET).read_bytes())
            self.assert_preserved(root, preserved)

    def test_packaging_rejects_installer_that_differs_from_reviewed_backport(self):
        read_bytes = Path.read_bytes

        def altered_source(path):
            data = read_bytes(path)
            return data + b'\n# unreviewed source\n' if path == CURRENT else data

        with tempfile.TemporaryDirectory() as directory:
            with patch.object(Path, 'read_bytes', altered_source):
                with self.assertRaises(RuntimeError):
                    extras.package(GUEST, Path(directory))


if __name__ == '__main__':
    unittest.main()
