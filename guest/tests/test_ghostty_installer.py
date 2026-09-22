from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

GUEST = Path(__file__).resolve().parents[1]
ASSETS = GUEST / 'native-overlay/usr/local/share/try-omarchy/ghostty'
INSTALLER = GUEST / 'native-overlay/usr/local/lib/try-omarchy/install-ghostty-arm64'
SPEC = json.loads((GUEST / 'spec.json').read_text())


class GhosttyTests(unittest.TestCase):
    def test_recipe_and_downloads_match_spec(self):
        pins = SPEC['supplyChain']['ghostty']
        for name, field in (('PKGBUILD', 'recipeSha256'), ('ghostty-wrapper', 'wrapperSha256')):
            self.assertEqual(hashlib.sha256((ASSETS / name).read_bytes()).hexdigest(), pins[field])
        result = subprocess.run(['bash', '-c', 'source "$1"; printf "%s\\n" "$pkgver" "$pkgrel" "${source[@]}" "${sha256sums[@]}"',
                                 'bash', str(ASSETS / 'PKGBUILD')], capture_output=True, text=True, check=True)
        fields = result.stdout.splitlines()
        self.assertEqual(fields[:2], [pins['version'], pins['pkgrel']])
        self.assertEqual(fields[2:6], [pins['sourceUrl'], pins['sourceUrl'] + '.minisig', pins['zigUrl'], 'ghostty-wrapper'])
        self.assertEqual(fields[6:8], [pins['sourceSha256'], pins['signatureSha256']])
        self.assertEqual(fields[8:], [pins['zigSha256'], pins['wrapperSha256']])
        self.assertIn(pins['signingKey'], (ASSETS / 'PKGBUILD').read_text())
        self.assertIn(pins['zigVersion'], pins['zigUrl'])
        self.assertEqual(GUEST / pins['recipe'], ASSETS / 'PKGBUILD')

    def test_launcher_accepts_only_reviewed_ghostty_pins(self):
        launcher = (GUEST.parent / 'macos/run-qemu-gpu.sh').read_text()
        helpers = launcher.split('def fail(message: str)', 1)[1].split('def load_json', 1)[0]
        helpers = 'def fail(message: str)' + helpers
        chain = launcher.split('supply_chain_keys = ', 1)[1].split('hyprland = exact_keys(', 1)[0]
        chain = 'supply_chain_keys = ' + chain
        component = launcher.split('ghostty = exact_keys(', 1)[1].split('vivaldi = exact_keys(', 1)[0]
        code = helpers + chain + 'ghostty = exact_keys(' + component
        exec(code, {'spec': SPEC})
        for field in SPEC['supplyChain']['ghostty']:
            with self.subTest(field=field):
                changed = json.loads(json.dumps(SPEC))
                changed['supplyChain']['ghostty'][field] = 'unreviewed'
                with self.assertRaisesRegex(SystemExit, 'Ghostty installer is not pinned'):
                    exec(code, {'spec': changed})
        missing = json.loads(json.dumps(SPEC))
        del missing['supplyChain']['ghostty']
        with self.assertRaisesRegex(SystemExit, 'supply chain has an unexpected schema'):
            exec(code, {'spec': missing})

    def test_signature_failure_stops_before_build(self):
        result = subprocess.run(['bash', '-c', 'set -e; source "$1"; srcdir=/unused; minisign() { return 42; }; prepare; echo continued',
                                 'bash', str(ASSETS / 'PKGBUILD')], capture_output=True, text=True)
        self.assertEqual(result.returncode, 42)
        self.assertNotIn('continued', result.stdout)

    def test_wrapper_scopes_rendering_and_preserves_arguments(self):
        for cmdline, expected in (('quiet omarchy.qemu_virgl=1 root=/dev/vda', '1'),
                                  ('omarchy.qemu_virgl=10', '0'), ('xomarchy.qemu_virgl=1', '0'), ('', '0')):
            with self.subTest(cmdline=cmdline), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                binary = root / 'real'
                binary.write_text('#!/usr/bin/env python3\nimport json, os, sys\nprint(json.dumps([os.environ["LIBGL_ALWAYS_SOFTWARE"], os.environ["GHOSTTY_RESOURCES_DIR"], sys.argv[1:]]))\n')
                binary.chmod(0o755)
                (root / 'cmdline').write_text(cmdline)
                script = (ASSETS / 'ghostty-wrapper').read_text().replace('real=/usr/lib/ghostty/ghostty', f'real={binary}').replace('/proc/cmdline', str(root / 'cmdline'))
                result = subprocess.run(['bash', '-c', script, 'ghostty', '-e', 'echo', 'hello world'],
                                        env={**os.environ, 'LIBGL_ALWAYS_SOFTWARE': '0'}, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), [expected, '/usr/share/ghostty', ['-e', 'echo', 'hello world']])
                binary.unlink()
                missing = subprocess.run(['bash', '-c', script], capture_output=True)
                self.assertEqual(missing.returncode, 127)

    def test_menu_routes_only_arm_ghostty_and_preserves_default_on_failure(self):
        patch = next(p for p in SPEC['authenticity']['backports'] if p['id'] == 'ghostty-arm64-terminal')
        fixture = (GUEST / 'tests/fixtures/omarchy-install-terminal').read_bytes()
        self.assertEqual(hashlib.sha256(fixture).hexdigest(), patch['targets'][0]['beforeSha256'])
        for arch, package, status in (('aarch64', 'ghostty', 0), ('aarch64', 'ghostty', 42),
                                       ('x86_64', 'ghostty', 0), ('aarch64', 'kitty', 0)):
            with self.subTest(arch=arch, package=package, status=status), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / 'bin').mkdir()
                target = root / 'bin/omarchy-install-terminal'
                target.write_bytes(fixture)
                subprocess.run(['git', 'apply', '--unsafe-paths', str(GUEST / patch['patch'])], cwd=root, check=True, capture_output=True)
                self.assertEqual(hashlib.sha256(target.read_bytes()).hexdigest(), patch['targets'][0]['afterSha256'])
                target.write_text(target.read_text().replace('/usr/local/lib/try-omarchy/install-ghostty-arm64', 'ghostty-installer'))
                for name, body in {'uname': f'echo {arch}', 'ghostty-installer': f'echo ghostty > "$HOME/called"; exit {status}',
                                   'omarchy-pkg-add': 'echo "generic $*" > "$HOME/called"'}.items():
                    stub = root / 'bin' / name
                    stub.write_text('#!/bin/bash\n' + body + '\n')
                    stub.chmod(0o755)
                (root / '.config' / package).mkdir(parents=True)
                config = root / '.config' / package / 'config'
                config.write_text('existing settings')
                preference = root / '.config/xdg-terminals.list'
                preference.write_text('Alacritty.desktop\n')
                result = subprocess.run(['bash', str(target), package], env={**os.environ, 'HOME': str(root), 'PATH': f'{root}/bin:' + os.environ['PATH']}, capture_output=True, text=True)
                self.assertEqual(result.returncode, 1 if status else 0, result.stderr)
                self.assertEqual((root / 'called').read_text().strip(), 'ghostty' if arch == 'aarch64' and package == 'ghostty' else f'generic {package}')
                self.assertEqual(config.read_text(), 'existing settings')
                self.assertEqual(preference.read_text() == 'Alacritty.desktop\n', bool(status))
                if not status:
                    self.assertIn('com.mitchellh.ghostty.desktop' if package == 'ghostty' else 'kitty.desktop', preference.read_text())

    def test_reinstall_uses_new_archive_with_stale_cached_package(self):
        # Exercise publication and installation with a previously cached build
        # of the same version. Model pacman's filename-based cache lookup for
        # -S and its direct archive selection for -U.
        publication = INSTALLER.read_text().split('# Publish before installation', 1)[1]
        publication = '# Publish before installation' + publication.split('# Discover', 1)[0]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for directory in ('repo', 'build', 'sync', 'cache'):
                (root / directory).mkdir()
            pins = SPEC['supplyChain']['ghostty']
            filename = f"ghostty-{pins['version']}-{pins['pkgrel']}-aarch64.pkg.tar.zst"
            package = root / 'build' / filename
            package.write_text('newly built package')
            cached = root / 'cache' / filename
            cached.write_text('previous build of the same version')
            script = r'''
set -euo pipefail
root=$1
package=$2
repo="$root/repo"
fail() { echo "$*" >&2; exit 1; }
sudo() { "$@"; }
install() { cp "${@: -2}"; }
repo-add() { cp "${@: -1}" "$repo/try-omarchy.db.tar.gz"; }
pacman() {
  case "$1" in
    -S)
      local archive="$root/cache/$(basename "$package")"
      cmp -s "$archive" "$root/sync/try-omarchy.db" || {
        echo 'invalid or corrupted package (checksum)' >&2
        return 1
      }
      cp "$archive" "$root/installed"
      ;;
    -U) cp "${@: -1}" "$root/installed" ;;
    -Qkk) cmp -s "$package" "$root/installed" ;;
    -Qn) cmp -s "$root/sync/try-omarchy.db" "$root/installed" ;;
    *) return 99 ;;
  esac
}
'''
            # Redirect only the system sync-cache destination into the sandbox.
            script += publication.replace('/var/lib/pacman/sync/try-omarchy.db',
                                          '"$root/sync/try-omarchy.db"')
            result = subprocess.run(['bash', '-c', script, 'installer', str(root), str(package)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((root / 'installed').read_bytes(), package.read_bytes())
            self.assertEqual((root / 'repo' / filename).read_bytes(), package.read_bytes())
            self.assertEqual(cached.read_text(), 'previous build of the same version')

    def test_tampered_assets_stop_before_package_operations(self):
        if os.geteuid() == 0:
            self.skipTest('installer intentionally refuses root')
        for name in ('PKGBUILD', 'ghostty-wrapper'):
            with self.subTest(asset=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                assets = root / 'guest/native-overlay/usr/local/share/try-omarchy/ghostty'
                shutil.copytree(ASSETS, assets)
                (root / 'guest/spec.json').write_text(json.dumps(SPEC))
                with (assets / name).open('a') as stream:
                    stream.write('\n# tampered\n')
                (root / 'bin').mkdir()
                for command, body in {'uname': 'echo aarch64', 'omarchy-pkg-add': 'touch "$HOME/unexpected"; exit 99', 'makepkg': 'touch "$HOME/unexpected"; exit 99'}.items():
                    stub = root / 'bin' / command
                    stub.write_text('#!/bin/bash\n' + body + '\n')
                    stub.chmod(0o755)
                result = subprocess.run(['bash', str(INSTALLER), '--from-checkout', str(root), '--build-only', str(root / 'out')],
                                        env={**os.environ, 'HOME': str(root), 'PATH': f'{root}/bin:' + os.environ['PATH']}, capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('digest mismatch', result.stderr)
                self.assertFalse((root / 'unexpected').exists())


if __name__ == '__main__':
    unittest.main()
