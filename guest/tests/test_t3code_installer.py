from __future__ import annotations
import contextlib
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

GUEST = Path(__file__).resolve().parents[1]
ASSETS = GUEST / 'native-overlay/usr/local/share/try-omarchy/t3code'
INSTALLER = GUEST / 'native-overlay/usr/local/lib/try-omarchy/install-t3code-arm64'
SPEC = json.loads((GUEST / 'spec.json').read_text())
BACKPORT = next(p for p in SPEC['authenticity']['backports'] if p['id'] == 't3code-arm64-desktop')


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


release = load('release', ASSETS / 'resolve-release.py')
installer = load('installer', INSTALLER)
PAYLOAD = b'fake ARM64 AppImage bytes'


def metadata(version='0.0.42'):
    name = f'T3-Code-{version}-arm64.AppImage'
    return dict(tag_name=f'v{version}', draft=False, prerelease=False, assets=[dict(
        name=name, browser_download_url=f'https://github.com/pingdotgg/t3code/releases/download/v{version}/{name}',
        digest='sha256:' + hashlib.sha256(PAYLOAD).hexdigest())])


def menu_entries(sign):
    # The patched menu rows, keyed by id, as the Omarchy menu parses them.
    entries = {}
    for line in (GUEST / BACKPORT['patch']).read_text().splitlines():
        if line.startswith(sign + '  "') and '.ai.t3-code"' in line:
            entries.update(json.loads('{' + line[1:].strip().rstrip(',') + '}'))
    return entries


def executable(path, body):
    path.write_text('#!/bin/bash\n' + body + '\n')
    path.chmod(0o755)


class T3CodeReleaseTests(unittest.TestCase):
    def test_latest_stable_version_is_not_pinned(self):
        for version in ('0.0.42', '0.1.0', '2.0.0'):
            self.assertEqual(release.resolve(metadata(version))[0], version)

    def test_untrusted_release_metadata_is_rejected(self):
        invalid = [[], 'release', dict(metadata(), assets=None), dict(metadata(), assets=['asset'])]
        for field, value in [('draft', True), ('prerelease', True), ('tag_name', 'v1.0.0; touch /tmp/bad'), ('assets', [])]:
            item = metadata(); item[field] = value; invalid.append(item)
        for field, value in [('browser_download_url', 'https://example.com/app'), ('digest', None), ('name', 'T3-Code-0.0.42-x86_64.AppImage')]:
            item = metadata(); item['assets'][0][field] = value; invalid.append(item)
        item = metadata(); item['assets'] *= 2; invalid.append(item)
        for item in invalid:
            with self.subTest(item=item), self.assertRaises(ValueError):
                release.resolve(item)

    def test_local_inputs_match_reviewed_spec_and_launcher(self):
        pins = SPEC['supplyChain']['t3code']
        for name, key in installer.ASSET_PINS.items():
            self.assertEqual(installer.sha256(ASSETS / name), pins[key])
        self.assertEqual(installer.sha256(INSTALLER), pins['installerSha256'])
        launcher = (GUEST.parent / 'macos/run-qemu-gpu.sh').read_text()
        for value in pins.values():
            self.assertIn(f'"{value}"', launcher)


def install(root, payload=PAYLOAD, fetch_error=None, remove=False):
    calls = []
    def fetch(url, destination):
        calls.append(('download', url))
        if fetch_error:
            raise fetch_error
        destination.write_bytes(json.dumps(metadata()).encode() if url.endswith('/latest') else payload)
    def run(*args, **kwargs):
        calls.append(args)
        if '--appimage-extract' in args:
            icon = kwargs['cwd'] / 'squashfs-root/usr/share/icons/hicolor/256x256/apps/t3code.png'
            icon.parent.mkdir(parents=True)
            icon.write_bytes(b'icon')
    with patch.dict(os.environ, {'XDG_DATA_HOME': str(root)}), \
         patch.object(installer, 'fetch', side_effect=fetch), \
         patch.object(installer, 'run', side_effect=run), \
         contextlib.redirect_stdout(io.StringIO()):
        installer.install(ASSETS, GUEST / 'spec.json', remove)
        return calls


class T3CodeInstallerTests(unittest.TestCase):
    def test_download_installs_intact_writable_appimage_and_launcher(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve() / 'space and % field'
            calls = install(root)
            app = root / 'try-omarchy/t3code'
            self.assertEqual((app / 'T3-Code.AppImage').read_bytes(), PAYLOAD)
            self.assertEqual((app / 'T3-Code.AppImage').stat().st_mode & 0o777, 0o755)
            self.assertIn('fuse2', next(c for c in calls if c[0] == 'omarchy-pkg-add'))
            entry = (root / 'applications/t3code.desktop').read_text()
            self.assertIn('%% field', entry)
            self.assertIn('t3code-wrapper" %U', entry)
            self.assertTrue((app / 't3').stat().st_mode & 0o111)

    def test_network_and_checksum_failure_do_not_install_app(self):
        for kwargs, error in [({'fetch_error': OSError('offline')}, OSError),
                              ({'payload': b'corrupted'}, ValueError)]:
            with self.subTest(kwargs=kwargs), tempfile.TemporaryDirectory() as temp:
                root = Path(temp).resolve()
                with self.assertRaises(error):
                    install(root, **kwargs)
                self.assertFalse((root / 'try-omarchy/t3code').exists())
                self.assertFalse((root / 'applications/t3code.desktop').exists())

    def test_reinstall_preserves_nightly_and_repairs_launcher_without_download(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            install(root)
            image = root / 'try-omarchy/t3code/T3-Code.AppImage'
            image.write_bytes(b'new nightly installed by T3 Code')
            (root / 'applications/t3code.desktop').unlink()
            calls = install(root, fetch_error=AssertionError('must not download stable'))
            self.assertEqual(image.read_bytes(), b'new nightly installed by T3 Code')
            self.assertTrue((root / 'applications/t3code.desktop').exists())
            self.assertFalse(any(c[0] == 'download' for c in calls))

    def test_remove_only_deletes_app_and_launcher(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            install(root)
            saved = root / '.t3'; saved.mkdir(); (saved / 'chat').write_text('keep')
            calls = install(root, remove=True)
            self.assertFalse((root / 'try-omarchy/t3code').exists())
            self.assertFalse((root / 'applications/t3code.desktop').exists())
            self.assertEqual((saved / 'chat').read_text(), 'keep')
            self.assertFalse(any(c[0] == 'download' for c in calls))

    def test_remove_drops_only_the_url_handler_that_launches_this_appimage(self):
        def handler_entry(target):
            # T3 Code's DesktopLinuxUrlHandler escaping, applied to $APPIMAGE.
            quoted = str(target)
            for old, new in (('\\', '\\\\'), ('`', '\\`'), ('$', '\\$'), ('"', '\\"'), ('%', '%%')):
                quoted = quoted.replace(old, new)
            quoted = f'"{quoted}"'.replace('\\', '\\\\')
            return f'[Desktop Entry]\nType=Application\nName=T3 Code\nExec={quoted} %U\nNoDisplay=true\n'
        for target, removed in (('try-omarchy/t3code/T3-Code.AppImage', True), ('Downloads/T3-Code-nightly.AppImage', False)):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as temp:
                root = Path(temp).resolve() / 'space and % field'
                install(root)
                handler = root / 'applications/com.t3tools.T3Code.desktop'
                handler.write_text(handler_entry(root / target))
                install(root, remove=True)
                self.assertEqual(handler.exists(), not removed)

    def test_removing_an_absent_app_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            install(root, remove=True)
            install(root, remove=True)
            self.assertFalse((root / 'try-omarchy/t3code').exists())

    def test_symlink_destinations_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve(); outside = root / 'outside'; outside.mkdir()
            (root / 'try-omarchy').symlink_to(outside)
            with self.assertRaisesRegex(ValueError, 'symlink'):
                install(root)
            self.assertEqual(list(outside.iterdir()), [])

    def test_wrapper_launches_appimage_with_flags_and_arguments(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve(); (root / 'config').mkdir()
            (root / 'config/t3code-flags.conf').write_text('# comment\n--ozone-platform=wayland\n')
            shutil.copyfile(ASSETS / 't3code-wrapper', root / 'wrapper')
            executable(root / 'T3-Code.AppImage', 'printf "%s\\n" "${ELECTRON_RUN_AS_NODE-electron}" "$@"')
            result = subprocess.run(['bash', str(root / 'wrapper'), 't3code://some/path'], capture_output=True, text=True, check=True,
                                    env={**os.environ, 'XDG_CONFIG_HOME': str(root / 'config'), 'ELECTRON_RUN_AS_NODE': '1'})
            self.assertEqual(result.stdout.splitlines(), ['electron', '--ozone-platform=wayland', 't3code://some/path'])


class T3CodeMenuTests(unittest.TestCase):
    def patched_scripts(self, root):
        (root / 'bin').mkdir()
        for name in ('omarchy-install-ai-t3-code', 'omarchy-remove-ai-t3-code'):
            shutil.copyfile(GUEST / 'tests/fixtures' / name, root / 'bin' / name)
        subprocess.run(['git', 'apply', '--include=bin/*', str(GUEST / BACKPORT['patch'])],
                       cwd=root, check=True, capture_output=True)
        for name in ('omarchy-install-ai-t3-code', 'omarchy-remove-ai-t3-code'):
            script = root / 'bin' / name
            script.write_text(script.read_text().replace('/usr/local/lib/try-omarchy/install-t3code-arm64', 'fake-installer'))
        executable(root / 'bin/uname', 'echo aarch64')

    def run_script(self, root, name):
        return subprocess.run(['bash', str(root / 'bin' / name)], capture_output=True, text=True,
                              env={**os.environ, 'HOME': str(root), 'PATH': f'{root / "bin"}:{os.environ["PATH"]}'})

    def test_install_stops_before_theme_and_launch_when_install_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve(); self.patched_scripts(root)
            executable(root / 'bin/fake-installer', 'exit 42')
            for name in ('omarchy-theme-set-t3code', 'omarchy-theme-refresh'):
                executable(root / 'bin' / name, 'touch "$HOME/theme"')
            self.assertEqual(self.run_script(root, 'omarchy-install-ai-t3-code').returncode, 42)
            self.assertFalse((root / 'theme').exists())

    def test_remove_deletes_app_package_and_t3_state_but_keeps_agent_state(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve(); self.patched_scripts(root)
            executable(root / 'bin/fake-installer', '[[ $1 == --remove ]] && touch "$HOME/removed"')
            executable(root / 'bin/omarchy-pkg-drop', 'echo "$@" >"$HOME/dropped"')
            for path in ('.t3/userdata', '.config/t3code', '.grok'):
                (root / path).mkdir(parents=True)
            result = self.run_script(root, 'omarchy-remove-ai-t3-code')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((root / 'removed').exists())
            self.assertEqual((root / 'dropped').read_text(), 't3code-bin\n', 'a locally built package is removed too')
            self.assertFalse((root / '.t3').exists() or (root / '.config/t3code').exists())
            self.assertTrue((root / '.grok').exists())

    def test_only_visibility_changes_in_the_menu_rows(self):
        upstream, patched = menu_entries('-'), menu_entries('+')
        self.assertEqual(set(patched), {'install.ai.t3-code', 'remove.ai.t3-code'})
        for key in patched:
            self.assertEqual({**upstream[key], 'when': ''}, {**patched[key], 'when': ''})

    def visible(self, root, data_home=None, package_installed=False):
        # Mirror MenuModel.guardLine: a row hides only when its guard fails.
        (root / 'bin').mkdir(parents=True, exist_ok=True)
        executable(root / 'bin/omarchy-pkg-present', 'exit 0' if package_installed else 'exit 1')
        env = {**os.environ, 'HOME': str(root), 'PATH': f'{root / "bin"}:{os.environ["PATH"]}'}
        env.pop('XDG_DATA_HOME', None)
        if data_home:
            env['XDG_DATA_HOME'] = str(data_home)
        shown = set()
        for key, entry in menu_entries('+').items():
            if subprocess.run(['bash', '-c', 'if { ' + entry['when'] + '; } >/dev/null 2>&1; then exit 0; else exit 1; fi'],
                              env=env).returncode == 0:
                shown.add(key.split('.')[0])
        return shown

    def test_menu_follows_the_installed_appimage(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve() / 'home with space'; root.mkdir()
            data = root / '.local/share'
            self.assertEqual(self.visible(root), {'install'})
            install(data)
            self.assertEqual(self.visible(root), {'remove'})
            (data / 'try-omarchy/t3code/T3-Code.AppImage').unlink()
            self.assertEqual(self.visible(root), {'install', 'remove'}, 'a partial install can be repaired or removed')
            install(data, remove=True)
            self.assertEqual(self.visible(root), {'install'})

    def test_menu_honours_custom_data_home_and_packaged_installs(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve(); custom = root / 'custom data'
            install(custom)
            self.assertEqual(self.visible(root), {'install'})
            self.assertEqual(self.visible(root, data_home=custom), {'remove'})
            self.assertEqual(self.visible(root / 'other', package_installed=True), {'remove'})


if __name__ == '__main__':
    unittest.main()
