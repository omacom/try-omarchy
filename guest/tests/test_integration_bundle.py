import importlib.util
import json
import os
import shutil
import stat
from types import SimpleNamespace
from pathlib import Path
import tempfile
import unittest
import subprocess
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]

def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result

builder = module('integration_builder', ROOT / 'integrations/build-bundle.py')
updater = module('integration_updater', ROOT / 'integrations/updater.py')

class IntegrationBundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        # macOS /var is a symlink; the production bundle must be canonical.
        self.bundle = Path(self.temp.name).resolve() / 'bundle'
        builder.build(self.bundle)

    def tearDown(self):
        self.temp.cleanup()

    def test_complete_bundle_is_verifiable(self):
        result = updater.manifest(self.bundle)
        self.assertEqual(result['version'], 1)
        self.assertIn('guest/scripts/install-touch-id-sudo.sh', result['files'])
        self.assertFalse(any(word in name for name in result['files'] for word in ('onepassword', 'clock-recover', 'repair-update-holds')))
        self.assertTrue((self.bundle / 'setup').stat().st_mode & 0o111)

    def test_smaller_bundle_does_not_remove_installed_support(self):
        import hashlib
        import shutil
        installed = self.bundle.parent / 'installed'
        shutil.copytree(self.bundle, installed)
        extra = installed / 'additional-integration'
        extra.write_text('retained support')
        data = json.loads((installed / 'manifest.json').read_text())
        data['files'][extra.name] = updater.digest(extra)
        data['identity'] = hashlib.sha256(json.dumps(data['files'], sort_keys=True).encode()).hexdigest()
        (installed / 'manifest.json').write_text(json.dumps(data))
        with self.assertRaisesRegex(RuntimeError, 'additional integrations'):
            updater.verify_upgrade(installed, self.bundle)
        self.assertEqual(extra.read_text(), 'retained support')
        updater.verify_upgrade(self.bundle, self.bundle)

    def test_matching_inventory_allows_repair_of_corrupt_installed_files(self):
        import shutil
        installed = self.bundle.parent / 'installed'
        shutil.copytree(self.bundle, installed)
        (installed / 'setup').write_text('damaged installed file')
        updater.verify_upgrade(installed, self.bundle)

    def test_corruption_cannot_execute(self):
        (self.bundle / 'setup').write_text('changed')
        with self.assertRaisesRegex(RuntimeError, 'verification failed'):
            updater.manifest(self.bundle)

    def test_symlink_substitution_is_rejected(self):
        target = self.bundle / 'setup'
        original = target.read_bytes()
        target.unlink()
        other = self.bundle.parent / 'outside'
        other.write_bytes(original)
        target.symlink_to(other)
        with self.assertRaisesRegex(RuntimeError, 'symlink'):
            updater.manifest(self.bundle)

    def test_manifest_traversal_rejected(self):
        path = self.bundle / 'manifest.json'
        data = json.loads(path.read_text())
        data['files']['../outside'] = 'a' * 64
        path.write_text(json.dumps(data))
        with self.assertRaisesRegex(RuntimeError, 'path|unexpected'):
            updater.manifest(self.bundle)

    def test_menu_refresh_preserves_entries_and_has_omarchy_environment(self):
        home = self.bundle.parent / 'home'
        menu = home / '.config/omarchy/extensions/omarchy-menu.jsonc'
        menu.parent.mkdir(parents=True)
        menu.write_text('{\n  "custom": {"label":"Keep me","action":"true"},\n}\n')
        with patch.object(updater, 'BUNDLE', self.bundle), patch.object(Path, 'home', return_value=home), patch.object(updater, 'run') as run:
            run.return_value = subprocess.CompletedProcess([], 0, '', '')
            with patch.dict(updater.os.environ, {}, clear=True):
                updater.menu_entry()
                updater.menu_entry()
            self.assertEqual(run.call_args.kwargs['env']['OMARCHY_PATH'], str(home / '.local/share/omarchy'))
        text = menu.read_text()
        self.assertIn('Keep me', text)
        self.assertEqual(text.count('"setup.try-omarchy-integrations"'), 1)
        self.assertEqual(text.count('"setup.security.touch-id"'), 1)

    def test_menu_upgrade_replaces_only_the_previous_generated_entry(self):
        menu = self.bundle.parent / 'menu.jsonc'
        old = '  "setup.try-omarchy-integrations": {"label":"Try Omarchy Integrations","action":"omarchy-launch-floating-terminal-with-presentation /usr/local/bin/try-omarchy-integrations"},\n'
        for custom in (False, True):
            entry = old.replace('Try Omarchy Integrations', 'My custom label') if custom else old
            menu.write_text('{\n' + entry + '  "custom": {"action":"true"},\n}\n')
            with patch.object(updater, 'BUNDLE', self.bundle):
                updater.menu_entry(menu, refresh=False)
            text = menu.read_text()
            self.assertIn('"custom": {"action":"true"}', text)
            self.assertEqual(text.count('"setup.try-omarchy-integrations"'), 1)
            if custom:
                self.assertIn(entry, text)
            else:
                self.assertNotIn(old, text)
                self.assertIn('xdg-terminal-exec', text)

    def test_incomplete_install_and_old_running_agent_are_not_current(self):
        state = self.bundle.parent / 'state'
        state.mkdir()
        identity = updater.manifest(self.bundle)['identity']
        with patch.object(updater, 'BUNDLE', self.bundle), patch.object(updater, 'STATE', state), patch.object(updater, 'files_current', return_value=True):
            (state / 'progress.json').write_text('{"status":"installing"}')
            self.assertEqual(updater.guest_status(identity)['components']['bootstrap'], 'repair')
            (state / 'progress.json').write_text('{"status":"complete"}')
            self.assertEqual(updater.guest_status(identity)['components']['bootstrap'], 'current')
            old = updater.guest_status('b' * 64)
            self.assertEqual(old['components']['bootstrap'], 'repair')
            self.assertEqual(old['identity'], 'b' * 64)

    def test_bootstrap_damage_is_reported_even_after_completed_install(self):
        state = self.bundle.parent / 'state'
        state.mkdir()
        (state / 'progress.json').write_text('{"status":"complete"}')
        pairs = {}
        for name in ['bootstrap', *updater.COMPONENTS]:
            pairs[name] = [(source, self.bundle.parent / 'guest' / str(target).lstrip('/'))
                           for source, target in updater.component_paths(name, self.bundle)]
        for source, target in sum(pairs.values(), []):
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        targets = {target for _, target in sum(pairs.values(), [])}
        original_stat = Path.stat
        wrong_owner = None

        def guest_stat(path, *args, **kwargs):
            info = original_stat(path, *args, **kwargs)
            if path in targets:
                fields = list(info)
                fields[4] = 1000 if path == wrong_owner else 0
                return os.stat_result(fields)
            return info

        with patch.object(updater, 'BUNDLE', self.bundle), \
             patch.object(updater, 'STATE', state), \
             patch.object(updater, 'component_paths', side_effect=lambda name, directory=None: pairs[name]), \
             patch.object(Path, 'stat', guest_stat):
            self.assertEqual(updater.guest_status()['components'], {'bootstrap': 'current', 'sudo': 'current'})
            for source, target in pairs['bootstrap']:
                for damage in ('missing', 'content', 'mode', 'owner', 'symlink'):
                    with self.subTest(file=target.name, damage=damage):
                        if damage == 'missing':
                            target.unlink()
                        elif damage == 'content':
                            target.write_text('damaged')
                        elif damage == 'mode':
                            target.chmod(0o600)
                        elif damage == 'owner':
                            wrong_owner = target
                        else:
                            target.unlink()
                            target.symlink_to(source)
                        self.assertEqual(updater.guest_status()['components'], {'bootstrap': 'repair', 'sudo': 'current'})
                        wrong_owner = None
                        target.unlink(missing_ok=True)
                        shutil.copy2(source, target)
                        self.assertEqual(updater.guest_status()['components']['bootstrap'], 'current')
            # Factory guests do not have an installation journal yet.
            (state / 'progress.json').unlink()
            self.assertEqual(updater.guest_status()['components']['bootstrap'], 'current')

    def test_failed_migration_retains_authentication_configuration_before_changes(self):
        originals = {
            '/etc/pam.d/sudo': (b'#%PAM-1.0\nlegacy broker rule\n', 0o644),
            '/var/lib/try-omarchy/native-authentication.json': (b'{"version":1,"enrollment":"original"}', 0o600),
            '/etc/skel/.config/omarchy/extensions/omarchy-menu.jsonc': (b'{"custom":{}}\n', 0o644),
        }
        # Use the production configuration inventory, redirected into a fake guest.
        self.assertEqual(set(map(str, updater.component_configuration_paths('sudo'))), set(originals))
        paths = [self.bundle.parent / 'guest' / name.lstrip('/') for name in originals]
        for target, (contents, mode) in zip(paths, originals.values()):
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(contents)
            target.chmod(mode)
        state = self.bundle.parent / 'state'
        original_read = Path.read_text

        def guest_read(path, *args, **kwargs):
            if str(path) == '/proc/cmdline':
                return 'omarchy.qemu_virgl=1'
            return original_read(path, *args, **kwargs)

        def fail_migration(args, **kwargs):
            self.assertEqual(args[0], '/bin/bash')
            backup = next(state.glob('sudo-backup-*'))
            for target, (contents, mode) in zip(paths, originals.values()):
                saved = backup / str(target).lstrip('/')
                self.assertEqual(saved.read_bytes(), contents)
                self.assertEqual(stat.S_IMODE(saved.stat().st_mode), mode)
                target.unlink()
            raise subprocess.CalledProcessError(1, args)

        with patch.object(updater, 'BUNDLE', self.bundle), \
             patch.object(updater, 'STATE', state), \
             patch.object(updater, 'STORE', self.bundle.parent / 'installed'), \
             patch.object(updater, 'component_configuration_paths', return_value=paths), \
             patch.object(updater, 'component_paths', return_value=[]), \
             patch.object(updater, 'files_current', return_value=False), \
             patch.object(updater, 'safe_destination'), \
             patch.object(updater.os, 'geteuid', return_value=0), \
             patch.object(updater.os, 'chown'), \
             patch.object(updater.pwd, 'getpwnam', return_value=SimpleNamespace(pw_uid=1000)), \
             patch.dict(os.environ, {'SUDO_UID': '1000'}), \
             patch.object(Path, 'read_text', guest_read), \
             patch.object(updater, 'run', side_effect=fail_migration):
            with self.assertRaises(subprocess.CalledProcessError):
                updater.install('guest', ['sudo'])
        backup = next(state.glob('sudo-backup-*'))
        self.assertEqual(stat.S_IMODE(backup.stat().st_mode), 0o700)
        for target, (contents, _) in zip(paths, originals.values()):
            self.assertFalse(target.exists())
            self.assertEqual((backup / str(target).lstrip('/')).read_bytes(), contents)
        self.assertEqual(json.loads((state / 'progress.json').read_text())['status'], 'installing')
        self.assertFalse((state / 'state.json').exists())

    def test_install_result_waits_after_success_or_failure(self):
        for choice in ('1',):
            for interactive in (True, False):
                for succeeds in (True, False):
                    with self.subTest(choice=choice, interactive=interactive, succeeds=succeeds):
                        events = []
                        def install(args, **kwargs):
                            self.assertEqual(args[0], 'sudo')
                            self.assertEqual(args[6:], ['sudo'])
                            events.append('install')
                            if not succeeds:
                                raise subprocess.CalledProcessError(1, args)
                        def answer(prompt):
                            if 'Choose' in prompt:
                                return choice
                            if 'Continue with installation' in prompt:
                                return 'y'
                            self.assertIn('Press Enter', prompt)
                            events.append('acknowledge')
                            return ''
                        def message(*args, **kwargs):
                            if str(args[0]).startswith('Integration setup could not complete'):
                                events.append('error')
                        with patch.object(updater, 'BUNDLE', self.bundle), \
                             patch.object(updater, 'files_current', return_value=True), \
                             patch.object(updater, 'component_paths', return_value=[]), \
                             patch.object(updater, 'run', side_effect=install), \
                             patch.object(updater, 'menu_entry', side_effect=lambda: events.append('refresh')), \
                             patch.object(updater.sys.stdin, 'isatty', return_value=interactive), \
                             patch('builtins.input', side_effect=answer), patch('builtins.print', side_effect=message):
                            if succeeds:
                                updater.review()
                            else:
                                with self.assertRaises(subprocess.CalledProcessError):
                                    updater.review()
                        expected = ['install', 'refresh'] if succeeds else ['install', 'error']
                        self.assertEqual(events, expected + (['acknowledge'] if interactive else []))

    def test_declined_install_and_exit_do_not_pause(self):
        for choice in ('1', '3'):
            answers = [choice, 'n'] if choice != '3' else [choice]
            with self.subTest(choice=choice), \
                 patch.object(updater, 'BUNDLE', self.bundle), \
                 patch.object(updater, 'files_current', return_value=True), \
                 patch.object(updater, 'component_paths', return_value=[]), \
                 patch.object(updater, 'run') as run, \
                 patch.object(updater.sys.stdin, 'isatty', return_value=True), \
                 patch('builtins.input', side_effect=answers), patch('builtins.print'):
                updater.review()
                run.assert_not_called()

    def test_unlisted_file_is_rejected(self):
        (self.bundle / 'extra').write_text('unreviewed')
        with self.assertRaisesRegex(RuntimeError, 'unexpected'):
            updater.manifest(self.bundle)

    def test_touch_id_result_waits_for_acknowledgement_and_preserves_failure(self):
        for interactive in (True, False):
            for status in (0, 1, 130):
                with self.subTest(interactive=interactive, status=status):
                    events = []
                    def touch_id(args):
                        self.assertEqual(args, ['/usr/local/bin/try-omarchy-touch-id'])
                        events.append('result')
                        if status:
                            raise subprocess.CalledProcessError(status, args)
                    def answer(prompt):
                        if 'Choose' in prompt:
                            return '2'
                        self.assertIn('Press Enter', prompt)
                        events.append('acknowledge')
                        return ''
                    with patch.object(updater, 'BUNDLE', self.bundle), \
                         patch.object(updater, 'files_current', return_value=True), \
                         patch.object(updater, 'run', side_effect=touch_id), \
                         patch.object(updater.sys.stdin, 'isatty', return_value=interactive), \
                         patch('builtins.input', side_effect=answer), patch('builtins.print'):
                        if status:
                            with self.assertRaises(subprocess.CalledProcessError) as error:
                                updater.review()
                            self.assertEqual(error.exception.returncode, status)
                        else:
                            updater.review()
                    self.assertEqual(events, ['result', 'acknowledge'] if interactive else ['result'])

    def test_future_bundle_is_not_installed_by_old_updater(self):
        path = self.bundle / 'manifest.json'
        data = json.loads(path.read_text())
        data['version'] = 2
        path.write_text(json.dumps(data))
        with self.assertRaisesRegex(RuntimeError, 'newer updater'):
            updater.manifest(self.bundle)

if __name__ == '__main__':
    unittest.main()
