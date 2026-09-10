from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class StaleRunCleanupTests(unittest.TestCase):
    def test_unavailable_or_incomplete_process_inventory_preserves_live_sockets(self):
        for mode, preserved in [('denied', True), ('empty', True), ('launcher', True), ('qemu', True), ('stale', False)]:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(prefix='try-omarchy-reaper-test-') as directory:
                candidate = Path(directory) / 'omarchy-qemu-gpu.ABCDEF'
                candidate.mkdir(mode=0o700)
                (candidate / '.run-qemu-gpu.owner').write_text('run-qemu-gpu:v1:111111:0')
                (candidate / '.qemu.pid').write_text('222222')
                (candidate / 'authentication.sock').write_text('test socket placeholder')
                source = (ROOT / 'macos/run-qemu-gpu.sh').read_text()
                function = source[source.index('reap_stale_work_dirs() {'):source.index('\nreap_stale_work_dirs\n')]
                function = function.replace('/private/tmp/omarchy-qemu-gpu.??????', directory + '/omarchy-qemu-gpu.??????')
                prologue = '''
_qps_owner() { id -u; }
_qps_permissions() { echo 700; }
ps() {
  case "$MODE" in
    denied) return 1 ;;
    empty) return 0 ;;
    launcher) printf '%s\\n' "$$" 111111 ;;
    qemu) printf '%s\\n' "$$" 222222 ;;
    stale) printf '%s\\n' "$$" ;;
  esac
}
'''
                subprocess.run(['/bin/bash', '-eu', '-c', prologue + function + '\nreap_stale_work_dirs'],
                               env={**os.environ, 'MODE': mode}, stdout=subprocess.DEVNULL, check=True)
                self.assertEqual(candidate.exists(), preserved)
