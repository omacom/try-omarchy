import base64
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import test_settings_install as support

fixes = support.fixes
spec = importlib.util.spec_from_file_location('boot_extras_tests', support.GUEST / 'scripts/boot-fix-components.py')
extras = importlib.util.module_from_spec(spec)
spec.loader.exec_module(extras)
spec = importlib.util.spec_from_file_location('user_fixes_tests', support.GUEST / 'scripts/migrate-user-fixes.py')
users = importlib.util.module_from_spec(spec)
spec.loader.exec_module(users)


class BootComponentTests(unittest.TestCase):
    def prepare(self, directory):
        payload = support.SettingsInstallTests().make_payload(directory)
        root = Path(directory) / 'root'
        root.mkdir()
        for relative, data in {
            'usr/lib/systemd/system/systemd-timesyncd.service': b'time service',
            'usr/lib/security/pam_faillock.so': b'PAM dependency',
            'usr/bin/openssl': b'openssl',
            'usr/lib/security/pam_exec.so': b'PAM dependency',
            'etc/pacman.conf': b'[options]\nIgnorePkg = personal-package # keep\n[core]\n',
            'usr/share/try-omarchy/pacman.conf': b'[options]\n[core]\n',
        }.items():
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        return payload, root

    def test_manual_repairs_are_applied_together_without_packages_or_enrollment(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, root = self.prepare(directory)
            result = fixes.migrate(payload, root, True, '')
            self.assertEqual('complete', result['state'])
            for component in ('clock', 'holds', 'lock', 'touch-id', 'integrations'):
                self.assertEqual('applied', result['components'][component])
            self.assertEqual('unavailable', result['components']['battery'])
            self.assertEqual('current', result['components']['onepassword'])
            self.assertIn('personal-package', (root / 'etc/pacman.conf').read_text())
            self.assertIn('linux-aarch64-headers', (root / 'etc/pacman.conf').read_text())
            self.assertEqual(extras.LINKS['etc/systemd/system/timers.target.wants/try-omarchy-clock-recovery.timer'],
                             os.readlink(root / 'etc/systemd/system/timers.target.wants/try-omarchy-clock-recovery.timer'))
            self.assertFalse((root / 'etc/pam.d/sudo').exists())
            self.assertFalse((root / 'var/lib/try-omarchy/native-authentication.json').exists())
            self.assertFalse((root / 'var/lib/pacman/db.lck').exists())

    def test_skip_leaves_clock_pam_and_integration_setup_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, root = self.prepare(directory)
            before = (root / 'etc/pacman.conf').read_bytes()
            result = fixes.migrate(payload, root, False, '')
            self.assertEqual('skipped', result['state'])
            for component in ('clock', 'holds', 'lock', 'touch-id', 'integrations'):
                self.assertEqual('pending', result['components'][component])
            self.assertEqual(before, (root / 'etc/pacman.conf').read_bytes())
            self.assertFalse((root / 'etc/pam.d/omarchy-lock-password').exists())

    def test_existing_pam_and_enrolled_older_touch_id_are_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, root = self.prepare(directory)
            for relative, content in {
                'etc/pam.d/omarchy-lock-password': 'my PAM policy',
                'var/lib/try-omarchy/native-authentication.json': '{"enrollment":"keep"}',
            }.items():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)
            result = fixes.migrate(payload, root, True, '')
            self.assertEqual('preserved', result['components']['lock'])
            self.assertEqual('preserved', result['components']['touch-id'])
            self.assertEqual('my PAM policy', (root / 'etc/pam.d/omarchy-lock-password').read_text())
            self.assertEqual('{"enrollment":"keep"}', (root / 'var/lib/try-omarchy/native-authentication.json').read_text())

    def test_write_failure_restores_configs_and_enablement_links(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, root = self.prepare(directory)
            before = (root / 'etc/pacman.conf').read_bytes()
            writer = fixes.write_file
            failed = False
            def fail(path, value, *args):
                nonlocal failed
                if path.name == 'omarchy-lock-password' and not failed:
                    failed = True
                    raise OSError('simulated full disk')
                return writer(path, value, *args)
            with patch.object(fixes, 'write_file', side_effect=fail):
                result = fixes.migrate(payload, root, True, '')
            self.assertEqual('failed', result['state'])
            self.assertEqual(before, (root / 'etc/pacman.conf').read_bytes())
            self.assertFalse((root / 'etc/systemd/system/timers.target.wants/try-omarchy-clock-recovery.timer').is_symlink())
            self.assertFalse((root / 'var/lib/pacman/db.lck').exists())

    def test_active_package_transaction_skips_hold_repair(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, root = self.prepare(directory)
            lock = root / 'var/lib/pacman/db.lck'
            lock.parent.mkdir(parents=True)
            lock.write_bytes(b'')
            result = fixes.migrate(payload, root, True, '')
            self.assertEqual('unavailable', result['components']['holds'])
            self.assertEqual(b'', lock.read_bytes())
            self.assertNotIn('linux-aarch64', (root / 'etc/pacman.conf').read_text())

    def test_disabled_clock_recovery_remains_disabled(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, root = self.prepare(directory)
            path = root / extras.GROUPS['clock']['try-omarchy-clock-recovery.timer'][0]
            path.write_bytes((payload / path.name).read_bytes())
            result = fixes.migrate(payload, root, True, '')
            self.assertEqual('preserved', result['components']['clock'])
            self.assertFalse((root / 'etc/systemd/system/timers.target.wants/try-omarchy-clock-recovery.timer').is_symlink())

    def test_disabled_battery_service_is_not_enabled_by_migration(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, root = self.prepare(directory)
            path = root / 'usr/lib/systemd/system/omarchy-native-battery-bridge.service'
            path.write_bytes((payload / path.name).read_bytes())
            result = fixes.migrate(payload, root, True, '')
            self.assertEqual('preserved', result['components']['battery'])
            self.assertFalse((root / 'etc/systemd/system/multi-user.target.wants/omarchy-native-battery-bridge.service').is_symlink())

    def test_current_upgrade_accepts_previous_battery_dkms_registration(self):
        relative = f'var/lib/dkms/try-omarchy-battery/kernel-{extras.kernel()}-aarch64'
        for version in ('1.0.0', '1.1.0', '1.2.0', extras.VERSION):
            self.assertTrue(extras.allowed_link(relative, f'{version}/{extras.kernel()}/aarch64'))
        self.assertFalse(extras.allowed_link(relative, f'custom/{extras.kernel()}/aarch64'))

    def test_user_pinch_and_menu_migration_preserves_existing_settings_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            payload = support.SettingsInstallTests().make_payload(directory)
            home = Path(directory) / 'home'
            path = home / '.config/hypr/input.lua'
            path.parent.mkdir(parents=True)
            path.write_text('-- my input settings\n')
            result = users.migrate(payload, home, False)
            self.assertEqual('skipped', result['state'])
            self.assertEqual('-- my input settings\n', path.read_text())
            result = users.migrate(payload, home, True)
            self.assertEqual('complete', result['state'])
            self.assertEqual('applied', result['outcome'])
            self.assertTrue(path.read_text().startswith('-- my input settings\n'))
            self.assertEqual(1, path.read_text().count('qemu-virtio-pinch-touchpad'))
            self.assertIn('setup.try-omarchy-integrations', (home / '.config/omarchy/extensions/omarchy-menu.jsonc').read_text())
            result = users.migrate(payload, home, True)
            self.assertEqual('current', result['outcome'])
            self.assertEqual(1, path.read_text().count('qemu-virtio-pinch-touchpad'))

    def test_runtime_activation_failure_restores_module_and_previous_service_state(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, root = self.prepare(directory)
            fixes.migrate(payload, root, False, '')  # Register the verified runtime implementation.
            target = root / 'usr/local/bin/omarchy-native-battery-bridge'
            target.parent.mkdir(parents=True)
            target.write_bytes(b'old bridge')
            before = fixes.snapshot(target, root, os.getuid())
            change = {'path': str(target.relative_to(root)), 'before': before,
                      'after': fixes.replacement(b'new bridge', os.getuid(), os.getgid())}
            runtime = {'services': {'omarchy-native-battery-bridge.service': True}, 'battery-loaded': True}
            restored = []
            with patch.object(fixes, 'restore_runtime', side_effect=lambda r, restoring: restored.append((r, restoring))):
                state = fixes.apply_transaction([change], root, os.getuid(), runtime,
                    activate=lambda _: (_ for _ in ()).throw(RuntimeError('load failed')))
            self.assertEqual('failed', state)
            self.assertEqual(b'old bridge', target.read_bytes())
            self.assertEqual([(runtime, True)], restored)

    def test_failed_battery_prebuild_does_not_change_any_battery_file(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, root = self.prepare(directory)
            for relative in ('usr/bin/dkms', f'usr/lib/modules/{extras.kernel()}/build',
                             'dev/virtio-ports/dev.tryomarchy.battery'):
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
            spec = importlib.util.spec_from_file_location('extra_failure', payload / 'components.py')
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            with patch.object(fixes, 'components', return_value=module), patch.object(module, 'build_battery', side_effect=RuntimeError('build failed')):
                result = fixes.migrate(payload, root, True, '')
            self.assertEqual('failed', result['state'])
            self.assertEqual('failed', result['components']['battery'])
            for relative, _ in extras.GROUPS['battery'].values():
                self.assertFalse((root / relative).exists())
            self.assertFalse((root / 'var/lib/dkms/try-omarchy-battery/1.3.0/source').is_symlink())

    def test_interrupted_enablement_is_recovered_on_skipped_boot(self):
        class Interrupted(BaseException):
            pass
        with tempfile.TemporaryDirectory() as directory:
            payload, root = self.prepare(directory)
            original = (root / 'etc/pacman.conf').read_bytes()
            writer = fixes.write_file
            def interrupted(path, value, *args):
                if path.name == 'omarchy-lock-password':
                    raise Interrupted()
                return writer(path, value, *args)
            with patch.object(fixes, 'write_file', side_effect=interrupted):
                with self.assertRaises(Interrupted):
                    fixes.migrate(payload, root, True, '')
            self.assertTrue((root / 'etc/systemd/system/timers.target.wants/try-omarchy-clock-recovery.timer').is_symlink())
            result = fixes.migrate(payload, root, False, '')
            self.assertEqual('skipped', result['state'])
            self.assertEqual(original, (root / 'etc/pacman.conf').read_bytes())
            self.assertFalse((root / 'etc/systemd/system/timers.target.wants/try-omarchy-clock-recovery.timer').is_symlink())

    def test_user_stale_alacritty_cleanup_keeps_verified_backup_and_preserves_custom_launchers(self):
        for custom in (False, True):
            with self.subTest(custom=custom), tempfile.TemporaryDirectory() as directory:
                payload = support.SettingsInstallTests().make_payload(directory)
                home = Path(directory) / 'home'
                entry = home / '.local/share/applications/Alacritty.desktop'
                entry.parent.mkdir(parents=True)
                data = b'my launcher' if custom else (support.GUEST / 'tests/fixtures/Alacritty.desktop').read_bytes()
                entry.write_bytes(data)
                with patch.object(users.shutil, 'which', return_value=None):
                    result = users.migrate(payload, home, True)
                self.assertEqual('complete', result['state'])
                self.assertEqual(custom, entry.exists())
                backup = entry.parent / '.Alacritty.desktop.try-omarchy-backup'
                if custom:
                    self.assertEqual('preserved', result['outcome'])
                    self.assertEqual(data, entry.read_bytes())
                    self.assertFalse(backup.exists())
                else:
                    self.assertEqual(data, backup.read_bytes())

    def test_battery_rollback_removes_new_empty_dkms_registration(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, root = self.prepare(directory)
            fixes.migrate(payload, root, False, '')
            source = 'usr/src/try-omarchy-battery-1.3.0/try-omarchy-battery.c'
            receipt = f'var/lib/dkms/try-omarchy-battery/1.3.0/{extras.kernel()}/aarch64/module/try_omarchy_battery.ko'
            link = 'var/lib/dkms/try-omarchy-battery/1.3.0/source'
            changes = [
                {'path': source, 'before': None, 'after': fixes.replacement(b'source', os.getuid(), os.getgid())},
                {'path': receipt, 'before': None, 'after': fixes.replacement(b'module', os.getuid(), os.getgid())},
                {'path': link, 'before': None, 'after': {'link': extras.LINKS[link], 'uid': os.getuid(), 'gid': os.getgid()}},
            ]
            self.assertEqual('complete', fixes.apply_transaction(changes, root, os.getuid()))
            fixes.recover(root, os.getuid(), fallback={'changes': changes, 'runtime': {}})
            self.assertFalse((root / 'var/lib/dkms/try-omarchy-battery').exists())
            self.assertFalse((root / 'usr/src/try-omarchy-battery-1.3.0').exists())
