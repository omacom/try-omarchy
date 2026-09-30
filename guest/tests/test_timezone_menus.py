"""Exercise the actual patched menus with isolated command boundaries."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

GUEST = Path(__file__).resolve().parents[1]
OVERLAY = GUEST / 'native-overlay'
SHARE = OVERLAY / 'usr/local/share/try-omarchy'
HELPER = '/usr/local/bin/try-omarchy-timezone'
spec = importlib.util.spec_from_file_location('timezone_menus', OVERLAY / 'usr/local/lib/try-omarchy/install-timezone-menus.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class TimezoneMenuTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.bin = self.root / 'usr/bin'
        self.bin.mkdir(parents=True)
        self.hooks = json.loads((SHARE / 'timezone-menu-hooks.json').read_text())
        for hook in self.hooks:
            target = self.root / hook['path']
            target.write_bytes((GUEST / 'tests/fixtures' / target.name).read_bytes())
            target.chmod(0o755)
        installer.install(self.root, self.hooks)
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'],
                        CAPTURE=str(self.root / 'capture'), CHOICE='', CANCEL='0')
        self.command('try-omarchy-timezone', '''
if [ "$1" = --mirror-label ]; then
  echo 'Mirror macOS (Asia/Tokyo)'
else
  printf '%s\\n' "$@" >"$CAPTURE.applied"
fi
''')
        self.command('timedatectl', "printf '%s\\n' Asia/Tokyo Europe/Lisbon UTC\n")
        self.command('gum', '''
printf '%s\\n' "$@" >"$CAPTURE.arguments"
cat >"$CAPTURE.options"
[ "$CANCEL" = 0 ] || exit "$CANCEL"
if [ -n "$CHOICE" ]; then printf '%s\\n' "$CHOICE"; else head -n 1 "$CAPTURE.options"; fi
''')
        self.command('omarchy-menu-select', 'exec gum "$@"\n')
        self.command('sudo', 'exec "$@"\n')
        self.command('omarchy-shell', ':\n')
        self.command('omarchy-notification-send', ':\n')

    def command(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/bash\n' + body)
        path.chmod(0o755)

    def shell(self, source):
        # Redirect only the system boundary; all picker logic stays unchanged.
        source = source.replace(HELPER, shlex.quote(str(self.bin / 'try-omarchy-timezone')))
        return subprocess.run(['bash', '-eu', '-c', source], env=self.env,
                              text=True, capture_output=True)

    def test_setup_defaults_to_mirror_and_keeps_fixed_zone_as_distinct_option(self):
        source = (SHARE / 'timezone-setup.sh').read_text()
        result = self.shell(source + '\nomarchy_prompt_timezone\nprintf "%s" "$timezone"\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'Mirror macOS (Asia/Tokyo)')
        self.assertEqual((self.root / 'capture.options').read_text().splitlines(),
                         ['Mirror macOS (Asia/Tokyo)', 'Asia/Tokyo', 'Europe/Lisbon', 'UTC'])
        self.assertIn('--selected\nMirror macOS (Asia/Tokyo)', (self.root / 'capture.arguments').read_text())
        self.assertFalse((self.root / 'capture.applied').exists())
        self.env['CHOICE'] = 'Asia/Tokyo'
        result = self.shell(source + '\nomarchy_prompt_timezone\nprintf "%s" "$timezone"\n')
        self.assertEqual(result.stdout, 'Asia/Tokyo')
        self.assertFalse((self.root / 'capture.applied').exists())

    def test_setup_cancel_propagates_without_saving_policy(self):
        for status in (1, 130):
            self.env['CANCEL'] = str(status)
            result = self.shell((SHARE / 'timezone-setup.sh').read_text() + '\nomarchy_prompt_timezone\n')
            self.assertEqual(result.returncode, status, result.stderr)
            self.assertFalse((self.root / 'capture.applied').exists())

    def test_owner_confirmation_applies_the_explicit_selection(self):
        owner = (self.bin / 'omarchy-provision-owner').read_text()
        function = 'configure_timezone() {' + owner.split('configure_timezone() {', 1)[1].split('\n}', 1)[0] + '\n}\n'
        for selection in ('Mirror macOS (Asia/Tokyo)', 'Asia/Tokyo'):
            result = self.shell(function + '\ntimezone=' + shlex.quote(selection) + '\nconfigure_timezone\n')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((self.root / 'capture.applied').read_text().splitlines(), ['--select', selection])

    def test_settings_menu_switches_both_directions_and_cancel_is_a_noop(self):
        menu = (self.bin / 'omarchy-menu-timezone').read_text()
        for selection in ('Mirror macOS (Asia/Tokyo)', 'Asia/Tokyo'):
            self.env['CHOICE'] = selection
            result = self.shell(menu)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((self.root / 'capture.applied').read_text().splitlines(), ['--select', selection])
        (self.root / 'capture.applied').unlink()
        self.env['CANCEL'] = '1'
        self.assertNotEqual(self.shell(menu).returncode, 0)
        self.assertFalse((self.root / 'capture.applied').exists())

    def test_boot_upgrade_matches_factory_backport_and_is_idempotent(self):
        build_spec = json.loads((GUEST / 'spec.json').read_text())
        backport = next(b for b in build_spec['authenticity']['backports'] if b['id'] == 'mirror-macos-timezone')
        for hook, target in zip(self.hooks, backport['targets']):
            path = self.root / hook['path']
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), target['afterSha256'])
            self.assertEqual(hook['beforeSha256'], target['beforeSha256'])
            self.assertEqual(path.stat().st_mode & 0o777, 0o755)
            inode = path.stat().st_ino
            installer.install(self.root, self.hooks)
            self.assertEqual(path.stat().st_ino, inode)
        patch = GUEST / backport['patch']
        self.assertEqual(hashlib.sha256(patch.read_bytes()).hexdigest(), backport['patchSha256'])
        # Independently apply the build patch to the same upstream fixtures.
        staged = self.root / 'factory'
        for target in backport['targets']:
            path = staged / target['path']
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes((GUEST / 'tests/fixtures' / path.name).read_bytes())
        subprocess.run(['git', 'apply', '--no-index', str(patch)], cwd=staged, check=True)
        for target in backport['targets']:
            self.assertEqual((staged / target['path']).read_bytes(), (self.root / 'usr' / target['path']).read_bytes())

    def test_boot_upgrade_leaves_unknown_scripts_and_symlinks_untouched(self):
        target = self.bin / 'omarchy-menu-timezone'
        target.write_text('my custom menu\n')
        installer.install(self.root, self.hooks)
        self.assertEqual(target.read_text(), 'my custom menu\n')
        owner = self.bin / 'omarchy-provision-owner'
        owner.unlink()
        owner.symlink_to(target)
        installer.install(self.root, self.hooks)
        self.assertTrue(owner.is_symlink())
        self.assertEqual(target.read_text(), 'my custom menu\n')
