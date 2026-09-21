import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


WRAPPER = Path(__file__).resolve().parents[1] / 'native-overlay/usr/local/bin/kitty'


class KittyWrapperTests(unittest.TestCase):
    def run_wrapper(self, cmdline, software=None, installed=True):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / 'kitty-real'
            if installed:
                binary.write_text('#!/usr/bin/env python3\nimport json, os, sys\n'
                                  'print(json.dumps([os.getenv("LIBGL_ALWAYS_SOFTWARE"), sys.argv[1:]]))\n')
                binary.chmod(0o755)
            wrapper = root / 'kitty'
            wrapper.write_text(WRAPPER.read_text().replace('real=/usr/bin/kitty', f'real={binary}'))
            command_line = root / 'cmdline'
            if cmdline is not None:
                command_line.write_text(cmdline)
            env = dict(os.environ, OMARCHY_KITTY_CMDLINE=str(command_line))
            env.pop('LIBGL_ALWAYS_SOFTWARE', None)
            if software is not None:
                env['LIBGL_ALWAYS_SOFTWARE'] = software
            return subprocess.run(['bash', str(wrapper), '--directory=/tmp/a b', '--', 'printf', '%s', 'hello world'],
                                  env=env, capture_output=True, text=True)

    def test_virgl_enables_software_and_preserves_arguments(self):
        result = self.run_wrapper('quiet omarchy.qemu_virgl=1 root=/dev/vda', '0')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), ['1', ['--directory=/tmp/a b', '--', 'printf', '%s', 'hello world']])

    def test_other_guests_preserve_environment(self):
        for cmdline in ('quiet', 'omarchy.qemu_virgl=10', 'xomarchy.qemu_virgl=1', None):
            for software in (None, '0'):
                with self.subTest(cmdline=cmdline, software=software):
                    result = self.run_wrapper(cmdline, software)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(json.loads(result.stdout)[0], software)

    def test_missing_package_reports_error(self):
        result = self.run_wrapper('omarchy.qemu_virgl=1', installed=False)
        self.assertEqual(result.returncode, 127)
        self.assertEqual(result.stderr.strip(), 'kitty is not installed')
