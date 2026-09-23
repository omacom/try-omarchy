#!/usr/bin/env python3
"""Exercise the patched HDA producer and consumer with bounded backend writes."""
from pathlib import Path
import hashlib
import os
import re
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / 'macos/patches/qemu-hda-full-ring-recovery.patch'


def function(source, name):
    start = source.index('static void ' + name + '(')
    end = source.index('\n}\n', start) + 3
    return source[start:end]


class HDARecoveryTests(unittest.TestCase):
    def test_patch_pin(self):
        builder = (ROOT / 'macos/build-qemu-gpu-runtime.sh').read_text()
        digest = re.search(r'^audio_recovery_patch_sha256=(\w+)$', builder, re.M)[1]
        self.assertEqual(hashlib.sha256(PATCH.read_bytes()).hexdigest(), digest)
        self.assertIn('"$audio_recovery_patch" "$audio_recovery_patch_sha256"', builder)
        self.assertIn('patch -d "$source_dir" -p1 -f -i "$audio_recovery_patch"', builder)

    def test_preserves_samples_and_bounds_catchup(self):
        # Compile the post-patch functions, including unchanged write/transfer loops.
        patched = '\n'.join(line[1:] for line in PATCH.read_text().splitlines()
                            if line.startswith((' ', '+')) and not line.startswith('+++'))
        functions = function(patched, 'hda_audio_output_timer') + function(patched, 'hda_audio_output_cb')
        harness = (ROOT / 'macos/Tests/hda-recovery-harness.c').read_text()
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'test.c'
            binary = Path(directory) / 'test'
            source.write_text(harness.replace('/* PATCHED_FUNCTIONS */', functions))
            subprocess.run(shlex.split(os.environ.get('CC', 'cc')) + [
                '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                '-fsanitize=address,undefined', str(source), '-o', str(binary)
            ], check=True)
            subprocess.run([str(binary)], check=True)


if __name__ == '__main__':
    unittest.main()
