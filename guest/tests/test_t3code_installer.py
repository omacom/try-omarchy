from __future__ import annotations
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

GUEST = Path(__file__).resolve().parents[1]
ASSETS = GUEST / 'native-overlay/usr/local/share/try-omarchy/t3code'
INSTALLER = GUEST / 'native-overlay/usr/local/lib/try-omarchy/install-t3code-arm64'
SPEC = json.loads((GUEST / 'spec.json').read_text())
module_spec = importlib.util.spec_from_file_location('release', ASSETS / 'resolve-release.py')
release = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(release)


def metadata(version='0.0.42'):
    name = f'T3-Code-{version}-arm64.AppImage'
    return dict(tag_name=f'v{version}', draft=False, prerelease=False, assets=[dict(
        name=name, browser_download_url=f'https://github.com/pingdotgg/t3code/releases/download/v{version}/{name}',
        digest='sha256:' + 'a' * 64)])


class T3CodeTests(unittest.TestCase):
    def test_latest_stable_version_is_not_pinned(self):
        for version in ('0.0.42', '0.1.0', '2.0.0'):
            self.assertEqual(release.resolve(metadata(version))[0], version)

    def test_untrusted_release_metadata_is_rejected(self):
        invalid = []
        for field, value in [('draft', True), ('prerelease', True), ('tag_name', 'v1.0.0; touch /tmp/bad'), ('assets', [])]:
            item = metadata(); item[field] = value; invalid.append(item)
        for field, value in [('browser_download_url', 'https://example.com/app'), ('digest', None), ('name', 'T3-Code-0.0.42-x86_64.AppImage')]:
            item = metadata(); item['assets'][0][field] = value; invalid.append(item)
        item = metadata(); item['assets'] *= 2; invalid.append(item)
        for item in invalid:
            with self.subTest(item=item), self.assertRaises(ValueError):
                release.resolve(item)

    def test_local_packaging_inputs_match_reviewed_spec(self):
        for name, field in [('PKGBUILD', 'recipeSha256'), ('t3code-wrapper', 'wrapperSha256'), ('t3', 'cliSha256'), ('resolve-release.py', 'resolverSha256')]:
            self.assertEqual(hashlib.sha256((ASSETS / name).read_bytes()).hexdigest(), SPEC['supplyChain']['t3code'][field])

    def run_installer(self, root, stubs, *args):
        (root / 'bin').mkdir(exist_ok=True)
        defaults = {name: 'exit 0' for name in ('fakeroot', 'bsdtar', 'repo-add', 'zstd', 'tar')}
        defaults.update({
            'uname': 'echo aarch64',
            'df': 'echo 10000000000',
            'vercmp': 'if [[ $1 == $2 ]]; then echo 0; elif [[ $1 > $2 ]]; then echo 1; else echo -1; fi',
        })
        for name, body in {**defaults, **stubs}.items():
            file = root / 'bin' / name
            file.write_text('#!/bin/bash\n' + body + '\n'); file.chmod(0o755)
        installer = root / 'installer'
        repo = root / 'repo'
        repo.mkdir(exist_ok=True)
        config = root / 'pacman.conf'
        config.write_text('[try-omarchy]\n')
        installer.write_text(INSTALLER.read_text().replace(
            'repo=/usr/share/try-omarchy/repo', f'repo={repo}').replace(
            '/etc/pacman.conf', str(config)))
        return subprocess.run(['bash', str(installer), '--from-checkout', str(GUEST.parent), *args],
                              env={**os.environ, 'HOME': str(root), 'XDG_CACHE_HOME': str(root / 'cache'),
                                   'PATH': str(root / 'bin') + ':' + os.environ['PATH']}, capture_output=True, text=True)

    def test_update_skips_uninstalled_and_held_apps_before_network(self):
        for present, hold in [(False, ''), (True, 't3code-bin'), (True, 't3*')]:
            with self.subTest(present=present, hold=hold), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                result = self.run_installer(root, {'pacman': 'exit ' + ('0' if present else '1'),
                    'pacman-conf': f'echo "{hold}"', 'curl': 'touch "$HOME/network"; exit 99'}, '--update')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse((root / 'network').exists())

    def test_network_failure_does_not_touch_packages(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result = self.run_installer(root, {'curl': 'exit 22', 'sudo': 'touch "$HOME/mutated"',
                'omarchy-pkg-add': 'touch "$HOME/mutated"'}, '--build-only', str(root / 'out'))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('installed app was not changed', result.stderr)
            self.assertFalse((root / 'mutated').exists())

    def test_update_current_newer_and_packaging_failure_preserve_install(self):
        for installed, expected_status, builds in [('0.0.42-1', 0, False), ('0.0.99-1', 0, False), ('0.0.41-1', 1, True)]:
            with self.subTest(installed=installed), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / 'release.json').write_text(json.dumps(metadata()))
                result = self.run_installer(root, {
                    'pacman': f'if [[ $1 == -Q ]]; then echo "t3code-bin {installed}"; fi; exit 0',
                    'pacman-conf': 'exit 0',
                    'curl': 'while (($#)); do if [[ $1 == -o ]]; then cp "$HOME/release.json" "$2"; exit; fi; shift; done; exit 99',
                    'omarchy-pkg-add': 'exit 0',
                    'makepkg': 'touch "$HOME/built"; exit 42',
                    'sudo': 'touch "$HOME/mutated"; exit 99',
                }, '--update')
                self.assertEqual(result.returncode, expected_status, result.stderr)
                self.assertEqual((root / 'built').exists(), builds)
                self.assertFalse((root / 'mutated').exists())

    def test_build_only_keeps_package_without_installing_it(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'release.json').write_text(json.dumps(metadata()))
            result = self.run_installer(root, {
                'curl': 'while (($#)); do if [[ $1 == -o ]]; then cp "$HOME/release.json" "$2"; exit; fi; shift; done; exit 99',
                'omarchy-pkg-add': 'exit 0',
                'makepkg': 'touch "$PKGDEST/t3code-bin-0.0.42-1-aarch64.pkg.tar.zst"',
                'pacman': '[[ $1 == -Qp ]] || exit 99; echo "t3code-bin 0.0.42-1"',
                'sudo': 'touch "$HOME/mutated"; exit 99',
            }, '--build-only', str(root / 'out'))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((root / 'out/t3code-bin-0.0.42-1-aarch64.pkg.tar.zst').is_file())
            self.assertFalse((root / 'mutated').exists())

    def test_menu_stops_before_theme_and_launch_when_install_fails(self):
        fixture = (GUEST / 'tests/fixtures/omarchy-install-ai-t3-code').read_text()
        backport = next(p for p in SPEC['authenticity']['backports'] if p['id'] == 't3code-arm64-desktop')
        self.assertEqual(hashlib.sha256(fixture.encode()).hexdigest(), backport['targets'][0]['beforeSha256'])
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); (root / 'bin').mkdir()
            target = root / 'bin/omarchy-install-ai-t3-code'; target.write_text(fixture)
            # The first file in this patch is the menu installer; the second is the updater.
            patch = (GUEST / backport['patch']).read_text().split('--- a/bin/omarchy-update\n')[0]
            subprocess.run(['patch', '-p1'], cwd=root, input=patch, text=True, check=True, capture_output=True)
            target.write_text(target.read_text().replace('/usr/local/lib/try-omarchy/install-t3code-arm64', 'fake-installer'))
            for name, body in {'uname':'echo aarch64', 'fake-installer':'exit 42',
                              'omarchy-theme-set-t3code':'touch "$HOME/theme"', 'omarchy-theme-refresh':'touch "$HOME/theme"'}.items():
                file=root/'bin'/name;file.write_text('#!/bin/bash\n'+body+'\n');file.chmod(0o755)
            result=subprocess.run(['bash',str(target)],env={**os.environ,'HOME':str(root),'PATH':str(root/'bin')+':'+os.environ['PATH']},capture_output=True)
            self.assertEqual(result.returncode,42)
            self.assertFalse((root/'theme').exists())


    def test_existing_guest_migration_is_idempotent_and_rejects_modified_commands(self):
        modspec = importlib.util.spec_from_file_location('integration', GUEST / 'scripts/install-t3code-integration.py')
        integration = importlib.util.module_from_spec(modspec); modspec.loader.exec_module(integration)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'usr/bin').mkdir(parents=True)
            (root / 'usr/share/try-omarchy').mkdir(parents=True)
            upstream = GUEST / 'tests/fixtures'
            for name in ('omarchy-update', 'omarchy-install-ai-t3-code'):
                shutil.copyfile(upstream / name, root / 'usr/bin' / name)
            old = copy.deepcopy(SPEC); del old['supplyChain']['t3code']
            specpath = root / 'usr/share/try-omarchy/build-spec.json'
            specpath.write_text(json.dumps(old))
            integration.install(GUEST, root)
            first = (root / 'usr/bin/omarchy-update').read_bytes()
            integration.install(GUEST, root)
            self.assertEqual(first, (root / 'usr/bin/omarchy-update').read_bytes())
            self.assertEqual(json.loads(specpath.read_text())['upstream'], old['upstream'])
            (root / 'usr/bin/omarchy-update').write_text('# user change')
            with self.assertRaisesRegex(ValueError, 'differs from the reviewed version'):
                integration.install(GUEST, root)
            self.assertEqual((root / 'usr/bin/omarchy-update').read_text(), '# user change')


if __name__ == '__main__':
    unittest.main()
