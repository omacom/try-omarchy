"""Exercise the guest profile commands and guarded existing-guest update."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

GUEST = Path(__file__).resolve().parents[1]
OVERLAY = GUEST / 'native-overlay'
SHARE = OVERLAY / 'usr/local/share/try-omarchy'
SPEC = importlib.util.spec_from_file_location('power_profile', OVERLAY / 'usr/local/lib/try-omarchy/install-power-profile.py')
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)


class PowerProfileTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.bin = self.root / 'usr/bin'
        self.bin.mkdir(parents=True)
        self.hooks = json.loads((SHARE / 'power-profile-hooks.json').read_text())
        for hook in self.hooks[:2]:
            path = self.root / hook['path']
            path.write_bytes((GUEST / 'tests/fixtures/power-profile' / path.name).read_bytes())
            path.chmod(0o755)
        installer.install(self.root, self.hooks)
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'],
                        OMARCHY_POWERPROFILES_STATE_DIR=str(self.root / 'state'))
        # These boundaries must never be used, even if a daemon is installed.
        for name in ('powerprofilesctl', 'busctl'):
            path = self.bin / name
            path.write_text('#!/bin/bash\necho called >>"$OMARCHY_POWERPROFILES_STATE_DIR"\nexit 99\n')
            path.chmod(0o755)

    def command(self, name, *args):
        return subprocess.run(['bash', str(self.bin / name), *args], env=self.env,
                              text=True, capture_output=True)

    def test_default_is_the_only_profile_and_is_active_without_a_daemon(self):
        result = self.command('omarchy-powerprofiles-list')
        self.assertEqual((result.returncode, result.stdout), (0, 'default\n'))
        result = self.command('omarchy-powerprofiles-list', '--active-state')
        self.assertEqual((result.returncode, result.stdout), (0, 'default\t1\n'))
        self.assertNotEqual(self.command('omarchy-powerprofiles-list', '--unknown').returncode, 0)
        self.assertFalse((self.root / 'state').exists())

    def test_startup_and_ac_transitions_do_not_change_policy(self):
        for args in ((), ('autodetect',), ('ac',), ('battery',)):
            result = self.command('omarchy-powerprofiles-set', *args)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, '', ''), args)
        for action in ('autodetect', 'ac', 'battery'):
            result = self.command('omarchy-powerprofiles-set', action, 'default')
            self.assertEqual((result.returncode, result.stdout), (0, 'Default, managed by macOS\n'))
        self.assertFalse((self.root / 'state').exists())

    def test_linux_modes_and_invalid_invocations_are_rejected(self):
        for args in (('ac', 'performance'), ('battery', 'balanced'), ('battery', 'power-saver'),
                     ('invalid',), ('ac', 'default', 'extra')):
            result = self.command('omarchy-powerprofiles-set', *args)
            self.assertNotEqual(result.returncode, 0, args)
            self.assertTrue(result.stderr, args)
        self.assertFalse((self.root / 'state').exists())

    def test_menu_provider_emits_the_same_label_with_no_control_action(self):
        provider = self.hooks[3]['replacements'][0][1]
        script = json.loads(provider.split('script: ', 1)[1].split('\n', 1)[0].rstrip(','))
        result = subprocess.run(['bash', '-c', script], env=self.env, text=True, capture_output=True)
        self.assertEqual((result.returncode, result.stdout),
                         (0, 'Default, managed by macOS\tdefault\tdefault\n'))
        self.assertIn('actionFor: function(value) { return "" }', provider)

    def test_boot_update_matches_factory_patch_and_preserves_mode(self):
        build_spec = json.loads((GUEST / 'spec.json').read_text())
        backport = next(b for b in build_spec['authenticity']['backports'] if b['id'] == 'macos-power-profile')
        for hook, target in zip(self.hooks, backport['targets']):
            self.assertEqual(hook['beforeSha256'], target['beforeSha256'])
            self.assertEqual(hook['afterSha256'], target['afterSha256'])
        patch = GUEST / backport['patch']
        self.assertEqual(hashlib.sha256(patch.read_bytes()).hexdigest(), backport['patchSha256'])
        staged = self.root / 'factory'
        for target in backport['targets'][:2]:
            path = staged / target['path']
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes((GUEST / 'tests/fixtures/power-profile' / path.name).read_bytes())
        subprocess.run(['git', 'apply', '--no-index', '--include=bin/*', str(patch)], cwd=staged, check=True)
        for target in backport['targets'][:2]:
            installed = self.root / 'usr' / target['path']
            self.assertEqual((staged / target['path']).read_bytes(), installed.read_bytes())
            self.assertEqual(installed.stat().st_mode & 0o777, 0o755)
            inode = installed.stat().st_ino
            installer.install(self.root, self.hooks)
            self.assertEqual(installed.stat().st_ino, inode)

    def test_unknown_files_and_symlinks_are_preserved(self):
        target = self.bin / 'omarchy-powerprofiles-list'
        target.write_text('custom profile list\n')
        other = self.bin / 'omarchy-powerprofiles-set'
        other.unlink()
        other.symlink_to(target)
        installer.install(self.root, self.hooks)
        self.assertEqual(target.read_text(), 'custom profile list\n')
        self.assertTrue(other.is_symlink())

    def test_bad_manifest_cannot_write_unreviewed_bytes(self):
        hook = dict(self.hooks[0])
        target = self.root / hook['path']
        original = (GUEST / 'tests/fixtures/power-profile' / target.name).read_bytes()
        target.write_bytes(original)
        hook['afterSha256'] = '0' * 64
        with self.assertRaises(ValueError):
            installer.install(self.root, [hook])
        self.assertEqual(target.read_bytes(), original)
        hook['path'] = 'etc/passwd'
        with self.assertRaises(ValueError):
            installer.install(self.root, [hook])
