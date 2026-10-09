import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import test_boot_components as support

fixes = support.fixes
extras = support.extras
GUEST = support.support.GUEST


class GhosttyMigrationTests(unittest.TestCase):
    def prepare(self, directory, recipe='ghostty-PKGBUILD-before-terminfo-fix'):
        payload, root = support.BootComponentTests().prepare(directory)
        legacy = {
            'install-ghostty-arm64': 'ghostty-installer-before-update-pins',
            'ghostty-PKGBUILD': recipe,
            'omarchy-install-terminal': 'omarchy-install-terminal',
        }
        preimages = json.loads((payload / 'preimages.json').read_text())
        for name, fixture in legacy.items():
            relative, mode = extras.GROUPS['ghostty'][name]
            data = (GUEST / 'tests/fixtures' / fixture).read_bytes()
            self.assertIn(hashlib.sha256(data).hexdigest(), preimages[relative])
            target = root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            target.chmod(mode)
        # Model the factory's old Ghostty pins, which must remain unchanged.
        old_spec = json.loads((GUEST / 'spec.json').read_text())
        old_spec['supplyChain']['ghostty']['pkgrel'] = '1'
        old_spec['supplyChain']['ghostty']['recipeSha256'] = hashlib.sha256(
            (GUEST / 'tests/fixtures/ghostty-PKGBUILD-before-terminfo-fix').read_bytes()).hexdigest()
        factory = root / 'usr/share/try-omarchy/build-spec.json'
        factory.parent.mkdir(parents=True, exist_ok=True)
        factory.write_text(json.dumps(old_spec))
        return payload, root, factory

    def test_update_repairs_menu_and_installer_pins_without_installing_ghostty(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, root, factory = self.prepare(directory)
            original = factory.read_bytes()
            result = fixes.migrate(payload, root, True, '')
            self.assertEqual('complete', result['state'])
            self.assertEqual('applied', result['components']['ghostty'])
            inodes = {}
            for name, (relative, mode) in extras.GROUPS['ghostty'].items():
                target = root / relative
                self.assertEqual((payload / name).read_bytes(), target.read_bytes())
                self.assertEqual(mode, target.stat().st_mode & 0o777)
                inodes[relative] = target.stat().st_ino
            self.assertEqual(original, factory.read_bytes())
            self.assertFalse((root / 'usr/bin/ghostty').exists())
            self.assertIn('/usr/local/lib/try-omarchy/install-ghostty-arm64',
                          (root / 'usr/bin/omarchy-install-terminal').read_text())
            # Execute the installed default path against the retained old
            # factory spec. Stop at dependency installation, after real asset
            # verification, without any package operation or compilation.
            if os.geteuid() != 0:
                installer = root / extras.GROUPS['ghostty']['install-ghostty-arm64'][0]
                script = installer.read_text().replace('assets=/usr/local/share/try-omarchy/ghostty',
                    f'assets={root}/usr/local/share/try-omarchy/ghostty').replace(
                    'spec=/usr/share/try-omarchy/build-spec.json', f'spec={factory}')
                commands = root / 'commands'
                commands.mkdir()
                for name, body in {'uname': 'echo aarch64',
                                   'omarchy-pkg-add': 'touch "$HOME/dependencies"; exit 42'}.items():
                    stub = commands / name
                    stub.write_text('#!/bin/bash\n' + body + '\n')
                    stub.chmod(0o755)
                process = subprocess.run(['bash', '-c', script, 'installer', '--build-only', str(root / 'out')],
                    env={**os.environ, 'HOME': str(root), 'PATH': str(commands) + ':' + os.environ['PATH']},
                    capture_output=True, text=True)
                self.assertEqual(1, process.returncode)
                self.assertTrue((root / 'dependencies').exists(), process.stderr)
                self.assertIn('could not install build dependencies', process.stderr)
                self.assertNotIn('digest mismatch', process.stderr)
            result = fixes.migrate(payload, root, True, '')
            self.assertEqual('current', result['components']['ghostty'])
            for relative, inode in inodes.items():
                self.assertEqual(inode, (root / relative).stat().st_ino)

    def test_update_replaces_the_bundled_fontconfig_recipe(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, root, factory = self.prepare(directory, 'ghostty-PKGBUILD-before-system-fontconfig')
            result = fixes.migrate(payload, root, True, '')
            self.assertEqual('applied', result['components']['ghostty'])
            recipe = root / extras.GROUPS['ghostty']['ghostty-PKGBUILD'][0]
            self.assertEqual((payload / 'ghostty-PKGBUILD').read_bytes(), recipe.read_bytes())
            self.assertIn('-fsys=fontconfig', recipe.read_text())

    def test_skipped_update_keeps_the_previous_installer_and_pins(self):
        with tempfile.TemporaryDirectory() as directory:
            payload, root, factory = self.prepare(directory)
            before = {relative: (root / relative).read_bytes() if (root / relative).exists() else None
                      for relative, _ in extras.GROUPS['ghostty'].values()}
            result = fixes.migrate(payload, root, False, '')
            self.assertEqual('pending', result['components']['ghostty'])
            for relative, data in before.items():
                target = root / relative
                self.assertEqual(data, target.read_bytes() if target.exists() else None)

    def test_custom_or_symlinked_files_preserve_the_whole_installer_group(self):
        for name in extras.GROUPS['ghostty']:
            for symlink in (False, True):
                with self.subTest(name=name, symlink=symlink), tempfile.TemporaryDirectory() as directory:
                    payload, root, factory = self.prepare(directory)
                    target = root / extras.GROUPS['ghostty'][name][0]
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.unlink(missing_ok=True)
                    if symlink:
                        target.symlink_to(factory)
                    else:
                        target.write_text('custom behavior')
                    before = {relative: (root / relative).read_bytes() if (root / relative).exists() else None
                              for relative, _ in extras.GROUPS['ghostty'].values()}
                    result = fixes.migrate(payload, root, True, '')
                    self.assertEqual('preserved', result['components']['ghostty'])
                    for relative, data in before.items():
                        path = root / relative
                        self.assertEqual(data, path.read_bytes() if path.exists() else None)
                    self.assertEqual(symlink, target.is_symlink())

    def test_failure_or_interruption_restores_installer_recipe_and_pins(self):
        class Interrupted(BaseException):
            pass
        for interrupt in (False, True):
            with self.subTest(interrupt=interrupt), tempfile.TemporaryDirectory() as directory:
                payload, root, factory = self.prepare(directory)
                before = {relative: fixes.snapshot(root / relative, root, os.getuid())
                          for relative, _ in extras.GROUPS['ghostty'].values()}
                writer = fixes.write_file
                failed = False
                def failing_write(path, value, *args):
                    nonlocal failed
                    if path == root / 'usr/bin/omarchy-install-terminal' and not failed:
                        failed = True
                        if interrupt:
                            raise Interrupted()
                        raise OSError('simulated disk failure')
                    return writer(path, value, *args)
                with patch.object(fixes, 'write_file', side_effect=failing_write):
                    if interrupt:
                        with self.assertRaises(Interrupted):
                            fixes.migrate(payload, root, True, '')
                    else:
                        result = fixes.migrate(payload, root, True, '')
                        self.assertEqual('failed', result['state'])
                if interrupt:
                    result = fixes.migrate(payload, root, False, '')
                    self.assertEqual('skipped', result['state'])
                for relative, original in before.items():
                    self.assertEqual(original, fixes.snapshot(root / relative, root, os.getuid()))


if __name__ == '__main__':
    unittest.main()
