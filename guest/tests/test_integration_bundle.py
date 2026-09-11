import importlib.util
import json
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
        self.assertIn('guest/scripts/install-onepassword-touch-id.sh', result['files'])
        self.assertTrue((self.bundle / 'setup').stat().st_mode & 0o111)

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
        with patch.object(updater, 'BUNDLE', self.bundle), patch.object(updater, 'STATE', state), patch.object(updater, 'files_current', return_value=True), patch.object(updater, 'active', return_value=True):
            (state / 'progress.json').write_text('{"status":"installing"}')
            self.assertEqual(updater.guest_status(identity)['components']['bootstrap'], 'repair')
            (state / 'progress.json').write_text('{"status":"complete"}')
            self.assertEqual(updater.guest_status(identity)['components']['bootstrap'], 'current')
            old = updater.guest_status('b' * 64)
            self.assertEqual(old['components']['bootstrap'], 'repair')
            self.assertEqual(old['identity'], 'b' * 64)

    def test_install_result_waits_after_success_or_failure(self):
        for choice in ('1', '3'):
            for interactive in (True, False):
                for succeeds in (True, False):
                    with self.subTest(choice=choice, interactive=interactive, succeeds=succeeds):
                        events = []
                        def install(args, **kwargs):
                            self.assertEqual(args[0], 'sudo')
                            self.assertEqual(args[6:], ['sudo', 'clock', 'holds'] if choice == '1' else ['onepassword'])
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
                             patch.object(updater, 'active', return_value=False), \
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
        for choice in ('1', '3', '4'):
            answers = [choice, 'n'] if choice != '4' else [choice]
            with self.subTest(choice=choice), \
                 patch.object(updater, 'BUNDLE', self.bundle), \
                 patch.object(updater, 'files_current', return_value=True), \
                 patch.object(updater, 'active', return_value=False), \
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
                         patch.object(updater, 'active', return_value=False), \
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
