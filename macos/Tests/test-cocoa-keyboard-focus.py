#!/usr/bin/env python3
"""Exercise QEMU's actual capture predicate without installing an event tap."""

import hashlib
import platform
import re
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / 'macos/patches/qemu-cocoa-full-grab-focus.patch'


def method(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


class KeyboardFocusTests(unittest.TestCase):
    def test_build_verifies_capture_patch(self):
        builder = (ROOT / 'macos/build-qemu-gpu-runtime.sh').read_text()
        digest = hashlib.sha256(PATCH.read_bytes()).hexdigest()
        self.assertIn(f'full_grab_patch_sha256={digest}', builder)

    @unittest.skipUnless(platform.system() == 'Darwin', 'requires Objective-C Foundation')
    def test_host_keeps_keyboard_after_focus_changes(self):
        added = '\n'.join(line[1:] for line in PATCH.read_text().splitlines()
                          if line.startswith(('+', ' ')) and not line.startswith('+++'))
        capture = method(added, '- (BOOL) isKeyboardCaptured\n')
        deactivate = method(added, '- (void) applicationDidResignActive:')
        harness = (ROOT / 'macos/Tests/cocoa-keyboard-focus-harness.m').read_text()
        harness = harness.replace('/* CAPTURE */', capture)
        harness = harness.replace('/* DEACTIVATE */', deactivate)
        with tempfile.TemporaryDirectory() as directory:
            # Apply the actual callback hunks to its pinned upstream body.
            # Exercise suppression/recovery without creating a global tap.
            callback = Path(directory) / 'ui/cocoa.m'
            callback.parent.mkdir()
            callback.write_text((ROOT / 'macos/Tests/cocoa-keyboard-tap-base.m').read_text())
            for patch in (PATCH, ROOT / 'macos/patches/qemu-cocoa-full-grab-reenable.patch'):
                chunks = re.split(r'(?=^@@ )', patch.read_text(), flags=re.M)
                hunk = next(chunk for chunk in chunks[1:]
                            if 'QemuCocoaView *view = userInfo;' in chunk)
                subprocess.run(['patch', '-d', directory, '-p1', '-F', '0', '-f'],
                               input='--- a/ui/cocoa.m\n+++ b/ui/cocoa.m\n' + hunk,
                               text=True, check=True, capture_output=True)
            harness = harness.replace('/* CALLBACK */', callback.read_text())
            source, binary = Path(directory) / 'test.m', Path(directory) / 'test'
            source.write_text(harness)
            subprocess.run(['xcrun', 'clang', '-Werror', '-framework', 'Foundation',
                            str(source), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)


if __name__ == '__main__':
    unittest.main()
