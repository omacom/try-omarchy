#!/usr/bin/env python3
"""Compile the patch's close-worker regression without fetching libslirp."""
import hashlib
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import unittest

NATIVE = Path(__file__).resolve().parents[1]
PATCH = NATIVE / "patches/libslirp-darwin-async-close.patch"
QEMU_PATCH = NATIVE / "patches/qemu-slirp-init-error.patch"


def added_file(name):
    lines = PATCH.read_text().splitlines(keepends=True)
    start = lines.index(f"+++ b/{name}\n") + 1
    result = []
    for line in lines[start:]:
        if line.startswith("diff --git "):
            break
        if line.startswith("@@"):
            continue
        if not line.startswith("+"):
            raise AssertionError(f"expected wholly added file {name}: {line!r}")
        result.append(line[1:])
    return "".join(result)


class ClosePatchTests(unittest.TestCase):
    def run_fixture(self, name, standard="c99", timeout=30):
        with tempfile.TemporaryDirectory(prefix="omarchy-close-test-") as temporary:
            root = Path(temporary)
            for source in ("src/close-worker.h", "src/close-worker.c", f"test/{name}.c"):
                target = root / source
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(added_file(source))
            binary = root / name
            subprocess.run([
                *shlex.split(os.environ.get("CC", "cc")),
                f"-std={standard}", "-Wall", "-Wextra", "-Werror", "-pthread",
                "-DSLIRP_TEST_ASYNC_CLOSE",
                *shlex.split(os.environ.get("CFLAGS", "")),
                str(root / f"test/{name}.c"), "-o", str(binary),
            ], check=True, timeout=60)
            subprocess.run([str(binary)], check=True, timeout=timeout)

    def test_stalled_closes_and_socket_lifetime(self):
        self.run_fixture("close-worker-test")

    @unittest.skipUnless(sys.platform == "darwin", "requires Darwin native timers")
    def test_adaptive_progress_and_timing_failures(self):
        self.run_fixture("close-worker-adaptive-test", standard="c11", timeout=90)

    @unittest.skipUnless(sys.platform == "darwin", "requires Darwin native address waits")
    def test_native_ready_wait_and_shutdown(self):
        self.run_fixture("close-worker-ready-test", standard="c11", timeout=90)

    @unittest.skipUnless(sys.platform.startswith("linux"), "requires Linux monotonic conditions")
    def test_linux_monitor_initialization_and_progress(self):
        self.run_fixture("close-worker-linux-monitor-test", standard="c11")

    def test_build_applies_pinned_patch(self):
        script = (NATIVE / "build-qemu-gpu-runtime.sh").read_text()
        pin = re.search(r"^close_patch_sha256=([0-9a-f]{64})$", script, re.M)
        self.assertIsNotNone(pin)
        self.assertEqual(pin.group(1), hashlib.sha256(PATCH.read_bytes()).hexdigest())
        self.assertIn('close_patch="$native_dir/patches/libslirp-darwin-async-close.patch"', script)
        self.assertIn('verify_file_sha "Darwin asynchronous TCP close patch" "$close_patch" "$close_patch_sha256"', script)
        apply = 'patch -d "$source_parent/$slirp_source_root" -p1 -f -i "$close_patch"'
        self.assertIn(apply, script)
        self.assertLess(script.index(apply), script.index('log "Building patched libslirp'))

    def test_build_applies_pinned_qemu_failure_path(self):
        script = (NATIVE / "build-qemu-gpu-runtime.sh").read_text()
        pin = re.search(r"^qemu_slirp_init_patch_sha256=([0-9a-f]{64})$", script, re.M)
        self.assertIsNotNone(pin)
        self.assertEqual(pin.group(1), hashlib.sha256(QEMU_PATCH.read_bytes()).hexdigest())
        self.assertIn('qemu_slirp_init_patch="$native_dir/patches/qemu-slirp-init-error.patch"', script)
        verify = 'verify_file_sha "Try Omarchy SLIRP initialization error patch"'
        apply = 'patch -d "$source_dir" -p1 -f -i "$qemu_slirp_init_patch"'
        self.assertIn(verify, script)
        self.assertIn(apply, script)
        self.assertLess(script.index(verify), script.index(apply))
        self.assertLess(script.index(apply), script.index('log "Building patched libslirp'))


if __name__ == "__main__":
    unittest.main()
