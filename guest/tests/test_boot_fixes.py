from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import test_settings_install as support

fixes = support.fixes
GUEST = support.GUEST


class BootFixTests(unittest.TestCase):
    def prepare(self, directory):
        helper = support.SettingsInstallTests()
        payload = helper.make_payload(directory)
        root = Path(directory) / "root"
        helper.seed_legacy_native_files(root)
        return payload, root

    def test_skip_changes_no_managed_files_and_reports_pending(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, root = self.prepare(directory)
            before = {p: p.read_bytes() for p in root.rglob('*') if p.is_file()}
            result = fixes.migrate(payload, root, False, '')
            self.assertEqual('skipped', result['state'])
            self.assertEqual('pending', result['components']['clipboard'])
            for path, data in before.items():
                self.assertEqual(data, path.read_bytes())
            self.assertFalse((root / fixes.FILES['omarchy-native-cursor-restore']).exists())

    def test_failed_step_restores_bytes_permissions_and_removes_new_helpers(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, root = self.prepare(directory)
            clipboard = root / fixes.FILES['omarchy-native-clipboard-bridge']
            clipboard.chmod(0o700)
            before = {p: (p.read_bytes(), p.stat().st_mode & 0o777) for p in root.rglob('*') if p.is_file()}
            writer = fixes.write_file
            failed = False
            def failing_write(path, value, *args):
                nonlocal failed
                if path.name == 'omarchy-screensaver' and not failed:
                    failed = True
                    raise OSError('simulated disk write failure')
                return writer(path, value, *args)
            with patch.object(fixes, 'write_file', side_effect=failing_write):
                result = fixes.migrate(payload, root, True, '')
            self.assertEqual('failed', result['state'])
            for path, (data, mode) in before.items():
                self.assertEqual(data, path.read_bytes())
                self.assertEqual(mode, path.stat().st_mode & 0o777)
            self.assertFalse((root / fixes.FILES['omarchy-native-cursor-restore']).exists())
            self.assertFalse((root / fixes.STATE / 'journal.json').exists())

    def test_interrupted_update_recovers_even_when_next_boot_skips(self):
        class PowerLoss(BaseException):
            pass
        with tempfile.TemporaryDirectory() as directory:
            payload, root = self.prepare(directory)
            clipboard = root / fixes.FILES['omarchy-native-clipboard-bridge']
            original = clipboard.read_bytes()
            writer = fixes.write_file
            def interrupted(path, value, *args):
                if path.name == 'omarchy-native-screensaver-text':
                    raise PowerLoss()
                return writer(path, value, *args)
            with patch.object(fixes, 'write_file', side_effect=interrupted):
                with self.assertRaises(PowerLoss):
                    fixes.migrate(payload, root, True, '')
            self.assertNotEqual(original, clipboard.read_bytes())
            result = fixes.migrate(payload, root, False, '')
            self.assertEqual('skipped', result['state'])
            self.assertEqual(original, clipboard.read_bytes())
            self.assertFalse((root / fixes.STATE / 'journal.json').exists())

    def test_recovery_failure_is_not_reported_as_restored_or_successful(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, root = self.prepare(directory)
            with patch.object(fixes, 'recover', side_effect=OSError('read-only disk')):
                result = fixes.migrate(payload, root, True, '')
            self.assertEqual('recovery-required', result['state'])

    def test_commit_flush_failure_still_restores_originals(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, root = self.prepare(directory)
            clipboard = root / fixes.FILES['omarchy-native-clipboard-bridge']
            original = clipboard.read_bytes()
            writer = fixes.write_file
            failed = False
            def failing_commit(path, value, *args):
                nonlocal failed
                writer(path, value, *args)
                if path.name == 'journal.json' and value is None and not failed:
                    failed = True
                    raise OSError('simulated commit directory flush failure')
            with patch.object(fixes, 'write_file', side_effect=failing_commit):
                result = fixes.migrate(payload, root, True, '')
            self.assertEqual('failed', result['state'])
            self.assertEqual(original, clipboard.read_bytes())

    def test_verification_failure_rolls_back_the_entire_group(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, root = self.prepare(directory)
            clipboard = root / fixes.FILES['omarchy-native-clipboard-bridge']
            original = clipboard.read_bytes()
            reader = fixes.snapshot
            reads = 0
            def bad_verification(path, *args):
                nonlocal reads
                value = reader(path, *args)
                if path == clipboard:
                    reads += 1
                    if reads == 3:  # plan, immediate preimage check, then verification
                        return None
                return value
            with patch.object(fixes, 'snapshot', side_effect=bad_verification):
                result = fixes.migrate(payload, root, True, '')
            self.assertEqual('failed', result['state'])
            self.assertEqual(original, clipboard.read_bytes())
            self.assertFalse((root / fixes.FILES['omarchy-native-cursor-restore']).exists())

    def test_corrupt_payload_is_rejected_before_migration(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, root = self.prepare(directory)
            (payload / 'omarchy-screensaver').write_text('corrupt')
            with self.assertRaises(RuntimeError):
                fixes.migrate(payload, root, True, '')

    def test_symlinked_parent_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, root = self.prepare(directory)
            original = root / 'usr/local/bin'
            kept = root / 'keep'
            original.rename(kept)
            original.symlink_to(kept)
            before = (kept / 'omarchy-native-clipboard-bridge').read_bytes()
            result = fixes.migrate(payload, root, True, '')
            self.assertEqual('preserved', result['components']['clipboard'])
            self.assertEqual(before, (kept / 'omarchy-native-clipboard-bridge').read_bytes())

    def test_success_verifies_all_steps_retains_backup_and_repeat_is_noop(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, root = self.prepare(directory)
            result = fixes.migrate(payload, root, True, '')
            self.assertEqual('complete', result['state'])
            self.assertEqual('applied', result['components']['screensaver'])
            backups = list((root / fixes.STATE).glob('backup-*.json'))
            self.assertEqual(1, len(backups))
            self.assertEqual(0o600, backups[0].stat().st_mode & 0o777)
            before = {p: p.stat().st_ino for p in root.rglob('*') if p.is_file()}
            result = fixes.migrate(payload, root, True, '')
            self.assertEqual('complete', result['state'])
            self.assertEqual('current', result['components']['screensaver'])
            for path, inode in before.items():
                self.assertEqual(inode, path.stat().st_ino)

    def test_alacritty_retirement_requires_runtime_and_retains_original(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, root = self.prepare(directory)
            wrapper = root / fixes.WRAPPER
            # The same exact factory fixture used by the helper's own tests.
            fixture = GUEST / 'tests/fixtures/alacritty-software-wrapper'
            self.assertTrue(fixture.is_file())
            wrapper.write_bytes(fixture.read_bytes())
            wrapper.chmod(0o755)
            binary = root / 'usr/bin/alacritty'
            binary.write_text('packaged terminal')
            binary.chmod(0o755)
            result = fixes.migrate(payload, root, True, '')
            self.assertEqual('unavailable', result['components']['alacritty'])
            self.assertTrue(wrapper.exists())
            result = fixes.migrate(payload, root, True, 'omarchy.virgl_dual_source=1')
            self.assertEqual('applied', result['components']['alacritty'])
            self.assertFalse(wrapper.exists())
            self.assertEqual(fixture.read_bytes(), (root / fixes.BACKUP).read_bytes())

    def test_settings_installation_does_not_bypass_migration_consent(self):
        from test_settings_install import installer
        with tempfile.TemporaryDirectory() as directory:
            payload, root = self.prepare(directory)
            clipboard = root / fixes.FILES['omarchy-native-clipboard-bridge']
            original = clipboard.read_bytes()
            installer.install_system(payload, root)
            self.assertEqual(original, clipboard.read_bytes())
