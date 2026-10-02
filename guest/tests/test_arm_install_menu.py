import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

GUEST = Path(__file__).resolve().parents[1]
OVERLAY = GUEST / 'native-overlay'


class ArmInstallMenuTests(unittest.TestCase):
    def test_bitwarden_package_routing_and_failure(self):
        script = (OVERLAY / 'usr/local/bin/omarchy-install-service-bitwarden').read_text()
        # The harness runs as the local test user, even when CI itself is root.
        script = script.replace('(( EUID == 0 ))', '(( 1 == 0 ))')
        for arch, failed, expected in (
            ('aarch64', '', ['repo bitwarden-cli desktop-file-utils', 'aur bitwarden-bin', 'launch']),
            ('x86_64', '', ['repo bitwarden bitwarden-cli', 'launch']),
            ('aarch64', 'repo', ['repo bitwarden-cli desktop-file-utils']),
            ('aarch64', 'aur', ['repo bitwarden-cli desktop-file-utils', 'aur bitwarden-bin']),
        ):
            with self.subTest(arch=arch, failed=failed), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                for name, body in {
                    'uname': f'echo {arch}',
                    'omarchy-pkg-add': 'echo "repo $*" >> "$LOG"; test "$FAIL" != repo',
                    'omarchy-pkg-aur-add': 'echo "aur $*" >> "$LOG"; test "$FAIL" != aur',
                    'setsid': 'echo launch >> "$LOG"',
                }.items():
                    path = root / name
                    path.write_text('#!/bin/bash\n' + body + '\n')
                    path.chmod(0o755)
                env = dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}', LOG=str(root / 'log'), FAIL=failed)
                # Wait for the launch stub instead of leaving an asynchronous test child.
                result = subprocess.run(['bash', '-c', script + '\nwait\n'], env=env, capture_output=True)
                self.assertEqual(result.returncode == 0, not failed)
                self.assertEqual((root / 'log').read_text().splitlines(), expected)

    def test_unavailable_map_does_not_block_supported_alternatives(self):
        entries = dict(line.split('\t') for line in (OVERLAY / 'usr/local/share/try-omarchy/aarch64-unavailable-packages').read_text().splitlines() if line and not line.startswith('#'))
        for package in ('hermes-desktop', 'ollama', 'ollama-cuda', 'ollama-rocm', 't3code-bin'):
            self.assertIn(package, entries)
        for package in ('bitwarden-bin', 'bitwarden-cli', 'desktop-file-utils'):
            self.assertNotIn(package, entries)

    def test_refusal_is_arm_only_and_returns_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ('omarchy-pkg-refuse-aarch64-unavailable', 'omarchy-pkg-unavailable-arm'):
                source = OVERLAY / 'usr/local/bin' / name
                path = root / name
                path.write_text(source.read_text().replace('/usr/local/bin/', str(root) + '/')
                                .replace('/usr/local/share/try-omarchy/', str(root) + '/'))
                path.chmod(0o755)
            shutil.copy2(OVERLAY / 'usr/local/share/try-omarchy/aarch64-unavailable-packages', root)
            uname = root / 'uname'
            for arch in ('aarch64', 'x86_64'):
                uname.write_text('#!/bin/bash\necho ' + arch + '\n')
                uname.chmod(0o755)
                for package in ('hermes-desktop', 'ollama', 't3code-bin', 'bitwarden-cli'):
                    result = subprocess.run([str(root / 'omarchy-pkg-refuse-aarch64-unavailable'), package],
                                            env=dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}'),
                                            text=True, capture_output=True)
                    refused = arch == 'aarch64' and package != 'bitwarden-cli'
                    self.assertEqual(result.returncode, int(refused))
                    self.assertEqual('not available' in result.stderr, refused)

    def test_migration_preview_apply_repeat_and_preserve_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            menu = root / 'usr/share/omarchy/default/omarchy/omarchy-menu.jsonc'
            menu.parent.mkdir(parents=True)
            shutil.copy2(GUEST / 'tests/fixtures/arm-install-menu.jsonc', menu)
            for command in ('omarchy-pkg-add', 'omarchy-pkg-aur-add'):
                path = root / 'usr/bin' / command
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('omarchy-pkg-refuse-aarch64-unavailable\n')
            package_map = root / 'usr/local/share/try-omarchy/aarch64-unavailable-packages'
            package_map.parent.mkdir(parents=True)
            package_map.write_text('# locally maintained map\ncustom-app\tCustom App\n')
            command = ['python3', str(GUEST / 'scripts/migrate-arm-install-menu.py'), '--root', str(root)]
            before = menu.read_bytes()
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            self.assertEqual(menu.read_bytes(), before)
            self.assertEqual(package_map.read_text(), '# locally maintained map\ncustom-app\tCustom App\n')
            result = subprocess.run(command + ['--apply'], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('omarchy-install-service-bitwarden', menu.read_text())
            self.assertIn('custom-app\tCustom App', package_map.read_text())
            self.assertNotIn('cursor-bin', package_map.read_text())
            self.assertEqual(len(list((root / 'var/lib/try-omarchy').iterdir())), 1)
            result = subprocess.run(command + ['--apply'], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('already applied', result.stdout)
            menu.write_text(menu.read_text() + '// custom change\n')
            modified = menu.read_bytes()
            self.assertNotEqual(subprocess.run(command + ['--apply'], capture_output=True).returncode, 0)
            self.assertEqual(menu.read_bytes(), modified)


if __name__ == '__main__':
    unittest.main()
