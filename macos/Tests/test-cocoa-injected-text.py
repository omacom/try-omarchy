#!/usr/bin/env python3
"""Exercise the patched Cocoa text path with real NSEvents and keyboard layouts."""
import hashlib
import platform
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / 'macos/patches/qemu-cocoa-injected-text.patch'


def block(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


class InjectedTextTests(unittest.TestCase):
    def test_build_uses_verified_patch(self):
        builder = (ROOT / 'macos/build-qemu-gpu-runtime.sh').read_text()
        digest = hashlib.sha256(PATCH.read_bytes()).hexdigest()
        self.assertIn(f'injected_text_patch_sha256={digest}', builder)
        self.assertIn('"$injected_text_patch" "$injected_text_patch_sha256"', builder)
        self.assertIn('patch -d "$source_dir" -p1 -f -i "$injected_text_patch"', builder)

    @unittest.skipUnless(platform.system() == 'Darwin', 'requires macOS keyboard layouts')
    def test_real_events_preserve_keyboard_behavior(self):
        added = '\n'.join(line[1:] for line in PATCH.read_text().splitlines()
                          if line.startswith(('+', ' ')) and not line.startswith('+++'))
        helpers = '\n'.join(block(added, marker) for marker in (
            'static UniChar cocoa_layout_character(', 'static bool cocoa_text_key('))
        method = block(added, '- (bool) handleInjectedText:')
        harness = (ROOT / 'macos/Tests/cocoa-injected-text-harness.m').read_text()
        harness = harness.replace('/* HELPERS */', helpers).replace('/* METHOD */', method)
        harness = harness.replace('/* QUEUE */', block(added, 'bool qemu_input_event_queue_has_room(size_t count)\n{'))
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'test.m'
            binary = Path(directory) / 'test'
            source.write_text(harness)
            subprocess.run(['xcrun', 'clang', '-Werror', '-framework', 'Cocoa',
                            '-framework', 'Carbon', str(source), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)


if __name__ == '__main__':
    unittest.main()
