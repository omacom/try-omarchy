#!/usr/bin/env python3

import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


NATIVE = Path(__file__).resolve().parents[1]
SCRIPT = NATIVE / "resize-vm-disk.sh"
GIB = 1024**3


class ResizeDiskTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="omarchy-resize-test.")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.state = self.root / "VM with spaces"
        self.source = self.root / "source.ext4"
        self.payload = b"existing guest data" + bytes(4096)
        self.source.write_bytes(self.payload)
        self.kernel = self.root / "kernel"
        self.kernel.write_bytes(bytes(56) + b"ARMd" + bytes(4))
        self.initramfs = self.root / "initramfs"
        self.initramfs.write_bytes(b"070701fixture")
        self.identity = hashlib.sha256(b"bundle").hexdigest()
        self.environment = dict(os.environ, OMARCHY_QEMU_GPU_STATE_ROOT=str(self.state),
                                OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK="0")
        self.environment.pop("OMARCHY_QEMU_GPU_TEST_FREE_BYTES", None)
        self.environment.pop("OMARCHY_QEMU_GPU_TEST_FS_TYPE", None)
        result = subprocess.run([
            "bash", "-eu", "-c",
            'source "$1"; qemu_persistent_storage_select persistent "$2" "$3" "$4" "$5" "" "$5" "$6" "$7" "root=/dev/vda rw rootwait console=tty0 console=hvc0"',
            "fixture", str(NATIVE / "qemu-persistent-storage.sh"), self.identity,
            str(self.source), hashlib.sha256(self.payload).hexdigest(), str(len(self.payload)),
            str(self.kernel), str(self.initramfs),
        ], env=self.environment, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.disk = self.state / "disks/current/rootfs.ext4"
        self.metadata = self.disk.with_name("metadata.json")

    def run_resize(self, *args, environment=None):
        return subprocess.run([str(SCRIPT), "--state-root", str(self.state), *args],
                              env=environment or self.environment, text=True, capture_output=True)

    def backups(self):
        return list(self.root.glob("VM with spaces.resize-backup.*"))

    def assert_rejected(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.disk.read_bytes(), self.payload)
        self.assertEqual(self.backups(), [])

    def launch_growth(self, gib, environment=None):
        return subprocess.run([
            "bash", "-eu", "-c",
            'source "$1"; qemu_persistent_storage_select_existing "$2"; '
            'qemu_persistent_storage_grow_selected "$3" "$4"',
            "launch-growth", str(NATIVE / "qemu-persistent-storage.sh"), self.identity,
            str(gib * GIB), str(NATIVE / ".build/debug/omarchy-vm-helper"),
        ], env=environment or self.environment, text=True, capture_output=True)

    def test_launcher_grows_sparsely_without_reserving_maximum_and_keeps_metadata(self):
        metadata = self.metadata.read_bytes()
        result = self.launch_growth(64, dict(self.environment, OMARCHY_QEMU_GPU_TEST_FREE_BYTES=str(2 * GIB)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.disk.stat().st_size, 64 * GIB)
        self.assertLess(self.disk.stat().st_blocks * 512, GIB)
        with self.disk.open("rb") as disk:
            self.assertEqual(disk.read(len(self.payload)), self.payload)
        self.assertEqual(self.metadata.read_bytes(), metadata)
        result = self.launch_growth(64)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.launch_growth(32)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("shrinking", result.stderr)
        self.assertEqual(self.disk.stat().st_size, 64 * GIB)

    def test_launcher_growth_requires_workspace_lock_and_valid_boot_kit(self):
        import fcntl
        with (self.state / "locks/current.lock").open("r+b") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assert_rejected(self.launch_growth(64))
        (self.state / "boot" / self.identity / "kernel").write_bytes(bytes(64))
        self.assert_rejected(self.launch_growth(64))

    def test_preview_preserves_disk_and_creates_no_backup(self):
        result = self.run_resize("--size-gib", "1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Preview only", result.stdout)
        self.assertEqual(self.disk.read_bytes(), self.payload)
        self.assertEqual(self.backups(), [])

    def test_growth_retains_verified_backup_and_is_idempotent(self):
        metadata = self.metadata.read_bytes()
        result = self.run_resize("--size-gib", "1", "--apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.disk.stat().st_size, GIB)
        self.assertEqual(self.disk.stat().st_mode & 0o777, 0o600)
        with self.disk.open("rb") as disk:
            self.assertEqual(disk.read(len(self.payload)), self.payload)
            disk.seek(GIB - 4096)
            self.assertEqual(disk.read(), bytes(4096))
        self.assertLess(self.disk.stat().st_blocks * 512, GIB)
        self.assertEqual(self.metadata.read_bytes(), metadata)
        backup, = self.backups()
        self.assertEqual(backup.stat().st_mode & 0o777, 0o700)
        self.assertEqual((backup / "rootfs.ext4").read_bytes(), self.payload)
        self.assertEqual((backup / "metadata.json").read_bytes(), metadata)
        self.assertEqual((backup / "boot" / self.identity / "kernel").read_bytes(), self.kernel.read_bytes())
        self.assertIn(hashlib.sha256(self.payload).hexdigest(), (backup / "resize.txt").read_text())
        result = self.run_resize("--size-gib", "1", "--apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("nothing changed", result.stdout)
        self.assertEqual(self.backups(), [backup])
        # The real launcher accepts a grown disk without rewriting its identity.
        result = subprocess.run(["bash", "-eu", "-c",
            'source "$1"; _qps_require_compatible_workspace "$2" "$3"',
            "verify", str(NATIVE / "qemu-persistent-storage.sh"), str(self.disk.parent), self.identity],
            env=self.environment, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_shrinking(self):
        with self.disk.open("r+b") as disk:
            disk.truncate(2 * GIB)
        result = self.run_resize("--size-gib", "1", "--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("shrinking", result.stderr)
        self.assertEqual(self.disk.stat().st_size, 2 * GIB)
        self.assertEqual(self.backups(), [])

    def test_rejects_invalid_and_overflowing_sizes(self):
        for value in ("0", "-1", "1.5", "01", "8193", "99999999999999999999999", "1G"):
            with self.subTest(value=value):
                self.assert_rejected(self.run_resize("--size-gib", value, "--apply"))

    def test_rejects_lock_held_by_launcher(self):
        import fcntl
        with (self.state / "locks/current.lock").open("r+b") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assert_rejected(self.run_resize("--size-gib", "1", "--apply"))

    def test_rejects_symlinked_disk(self):
        self.disk.rename(self.root / "original.ext4")
        self.disk.symlink_to(self.root / "original.ext4")
        self.assert_rejected(self.run_resize("--size-gib", "1", "--apply"))

    def test_rejects_hardlinked_disk(self):
        os.link(self.disk, self.root / "alias.ext4")
        self.assert_rejected(self.run_resize("--size-gib", "1", "--apply"))

    def test_rejects_corrupt_marker_and_preserves_it(self):
        marker = self.state / ".omarchy-qemu-storage"
        marker.write_text("unrecognized\n")
        self.assert_rejected(self.run_resize("--size-gib", "1", "--apply"))
        self.assertEqual(marker.read_text(), "unrecognized\n")

    def test_rejects_corrupt_boot_kit(self):
        (self.state / "boot" / self.identity / "kernel").write_bytes(bytes(64))
        self.assert_rejected(self.run_resize("--size-gib", "1", "--apply"))

    def test_rejects_insufficient_space_and_unsupported_filesystem(self):
        for overrides in ({"OMARCHY_QEMU_GPU_TEST_FREE_BYTES": "1"},
                          {"OMARCHY_QEMU_GPU_TEST_FS_TYPE": "exfat"}):
            with self.subTest(overrides=overrides):
                self.assert_rejected(self.run_resize("--size-gib", "1", "--apply",
                    environment=dict(self.environment, **overrides)))

    def test_rejects_insecure_disk_permissions(self):
        self.disk.chmod(0o644)
        self.assert_rejected(self.run_resize("--size-gib", "1", "--apply"))

    def test_rejects_legacy_and_unrecognized_metadata(self):
        original = self.metadata.read_text()
        for content in (original.replace('"schemaVersion":2', '"schemaVersion":1'), "{}\n"):
            with self.subTest(content=content):
                self.metadata.write_text(content)
                self.assert_rejected(self.run_resize("--size-gib", "1", "--apply"))
                self.assertEqual(self.metadata.read_text(), content)

    def test_rejects_development_multi_disk_mode(self):
        self.assert_rejected(self.run_resize("--size-gib", "1", "--apply",
            environment=dict(self.environment, OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK="1")))

    def test_missing_state_is_not_initialized(self):
        missing = self.root / "missing"
        result = self.run_resize("--state-root", str(missing), "--size-gib", "1", "--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(missing.exists())
        self.assertEqual(self.backups(), [])


if __name__ == "__main__":
    unittest.main()
