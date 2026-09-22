#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "network-identity.py"
spec = importlib.util.spec_from_file_location("network_identity", SCRIPT)
identity = importlib.util.module_from_spec(spec)
spec.loader.exec_module(identity)


class NetworkIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "locks").mkdir(mode=0o700)
        self.lock = self.root / "locks/current.lock"
        self.lock.touch(mode=0o600)
        self.records = self.root / "network-identities"
        self.record = self.records / "current.json"

    def run_identity(self, action="ensure", *args):
        return identity.identity(action, str(self.root), "current", *args)

    def legacy(self):
        self.records.mkdir(mode=0o700)
        value = {"disk": [1, 2, 3.0], "mac": "02:11:22:33:44:55"}
        self.record.write_text(json.dumps(value))
        self.record.chmod(0o600)
        return value

    def test_migrate_legacy_preserves_address_and_backup(self):
        old = self.legacy()
        self.assertEqual(self.run_identity("show"), old["mac"])
        self.assertEqual(json.loads(self.record.read_text()), old)
        self.assertEqual(self.run_identity(), old["mac"])
        value = json.loads(self.record.read_text())
        self.assertEqual(value["version"], 2)
        self.assertEqual(json.loads((self.records / "current.previous.json").read_text()), old)
        self.assertEqual(self.run_identity(), old["mac"])

    def test_disk_replacement_and_move_preserve_identity(self):
        disk = self.root / "rootfs.ext4"
        disk.write_bytes(b"original")
        mac = self.run_identity()
        saved = self.record.read_bytes()
        replacement = self.root / "replacement.ext4"
        replacement.write_bytes(b"upgraded")
        replacement.replace(disk)
        self.assertEqual(self.run_identity(), mac)
        moved = self.root / "moved"
        moved.mkdir(mode=0o700)
        self.records.rename(moved / "network-identities")
        self.assertEqual(identity.identity("ensure", str(moved)), mac)
        self.assertEqual((moved / "network-identities/current.json").read_bytes(), saved)

    def test_regenerate_preserves_vm_id_and_requires_current_mac(self):
        mac = self.run_identity()
        old = json.loads(self.record.read_text())
        new = identity.new_mac()
        with self.assertRaises(identity.IdentityError):
            self.run_identity("replace", identity.new_mac(), new)
        self.assertEqual(self.run_identity("replace", mac, new), new)
        self.assertEqual(json.loads(self.record.read_text())["vmID"], old["vmID"])
        self.assertEqual(json.loads((self.records / "current.previous.json").read_text()), old)
        self.assertEqual(self.record.stat().st_mode & 0o777, 0o600)

    def test_running_vm_lock_prevents_regeneration(self):
        mac = self.run_identity()
        # Exactly the lock acquisition used by qemu-persistent-storage.sh.
        process = subprocess.Popen(["/bin/bash", "-c",
            'exec 9>>"$1"; /usr/bin/lockf -s -t 0 9 || exit; echo ready; read answer',
            "lock-test", str(self.lock)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(process.stdout.readline().strip(), "ready")
            with self.assertRaisesRegex(identity.IdentityError, "Shut down"):
                self.run_identity("check")
            with self.assertRaisesRegex(identity.IdentityError, "Shut down"):
                self.run_identity("replace", mac, identity.new_mac())
            self.assertEqual(self.run_identity("show"), mac)
        finally:
            process.communicate("done\n", timeout=5)

    def test_invalid_records_fail_without_replacement(self):
        self.legacy()
        for value in [b"broken", b"[]", b'{"mac":"02:11:22:33:44:55"}',
                      b'{"version":3,"mac":"02:11:22:33:44:55","vmID":"unknown"}',
                      b'{"version":2,"mac":"02:11:22:33:44:55","vmID":123}',
                      b'{"disk":[1,2,3],"mac":"ff:ff:ff:ff:ff:ff"}']:
            self.record.write_bytes(value)
            with self.assertRaises(identity.IdentityError):
                self.run_identity()
            self.assertEqual(self.record.read_bytes(), value)

    def test_unsafe_record_is_not_followed_or_replaced(self):
        self.run_identity()
        self.record.chmod(0o644)
        with self.assertRaises(identity.IdentityError):
            self.run_identity()
        self.record.chmod(0o600)
        target = self.records / "target"
        self.record.rename(target)
        self.record.symlink_to(target)
        with self.assertRaises(OSError):
            self.run_identity()
        self.assertTrue(target.exists())

    def test_missing_record_is_read_without_creating_state(self):
        self.assertEqual(self.run_identity("show"), "")
        self.assertFalse(self.records.exists())

    def test_separate_vm_generates_separate_identity(self):
        mac = self.run_identity()
        separate = self.root / "separate"
        separate.mkdir(mode=0o700)
        self.assertNotEqual(identity.identity("ensure", str(separate)), mac)

    def test_concurrent_first_launch_has_one_identity(self):
        processes = [subprocess.Popen(["python3", str(SCRIPT), "ensure", str(self.root)],
                                      stdout=subprocess.PIPE, text=True) for _ in range(8)]
        values = [process.communicate(timeout=10)[0].strip() for process in processes]
        self.assertTrue(all(process.returncode == 0 for process in processes))
        self.assertEqual(len(set(values)), 1)
        self.assertTrue(identity.valid_mac(values[0]))


if __name__ == "__main__":
    unittest.main()
