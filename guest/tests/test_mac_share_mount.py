"""Exercise the real mount helper with disposable devices and mount-command shims."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HELPER = Path(__file__).resolve().parents[1] / "native-overlay/usr/local/bin/omarchy-native-mac-share"


class MacShareMountTests(unittest.TestCase):
    def test_boot_unit_can_execute_from_a_readonly_payload(self):
        unit = (HELPER.parents[5] / "macos/guest-settings.service").read_text()
        # systemd reapplies RuntimeDirectory ownership/mode before each command.
        # Once the payload covers that directory, this fails with EROFS.
        self.assertNotIn("RuntimeDirectory=", unit)
        self.assertIn("ExecStartPre=/usr/bin/mkdir -p /run/try-omarchy-settings", unit)
        self.assertIn("-o ro,trans=virtio,version=9p2000.L", unit)
        self.assertIn("ExecStartPre=/usr/bin/bash /run/try-omarchy-settings/omarchy-native-mac-share --mount", unit)

    def run_mount(self, *, enabled=True, mounted=False, mount_status=0):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            commands = root / "bin"
            commands.mkdir()
            device = root / "virtio/virtio1"
            device.mkdir(parents=True)
            (device / "mount_tag").write_bytes(b"mac\0")
            cmdline = root / "cmdline"
            cmdline.write_text("omarchy.shared_folder_name=V29yaw" if enabled else "root=/dev/vda")
            log = root / "mount.json"
            shims = {
                "modprobe": "#!/bin/sh\nexit 0\n",
                "mountpoint": f"#!/bin/sh\nexit {0 if mounted else 1}\n",
                "mount": "#!/usr/bin/env python3\nimport json, os, sys\n"
                         "open(os.environ['MOUNT_LOG'], 'w').write(json.dumps(sys.argv[1:]))\n"
                         f"sys.exit({mount_status})\n",
            }
            for name, content in shims.items():
                shim = commands / name
                shim.write_text(content)
                shim.chmod(0o755)
            env = dict(os.environ, PATH=f"{commands}:{os.environ['PATH']}",
                       OMARCHY_MAC_SHARE_VIRTIO_ROOT=str(root / "virtio"),
                       OMARCHY_MAC_SHARE_CMDLINE=str(cmdline),
                       OMARCHY_MAC_SHARE_MOUNT_POINT=str(root / "share"),
                       MOUNT_LOG=str(log))
            result = subprocess.run(["bash", str(HELPER), "--mount"], env=env,
                                    capture_output=True, text=True)
            args = json.loads(log.read_text()) if log.exists() else None
            return result, args

    def test_share_never_enables_writeback(self):
        result, args = self.run_mount()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(args[:4], ["-t", "9p", "-o",
                                   "trans=virtio,version=9p2000.L,msize=1048576,cache=readahead"])
        self.assertEqual(args[4], "mac")

    def test_disabled_share_does_not_mount(self):
        result, args = self.run_mount(enabled=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(args)

    def test_mount_failure_never_retries_with_writeback(self):
        result, args = self.run_mount(mount_status=32)
        self.assertEqual(result.returncode, 32)
        self.assertIn("cache=readahead", args[3])
        self.assertNotIn("mounted the shared Mac folder", result.stderr)

    def test_existing_mount_is_not_remounted_during_active_work(self):
        result, args = self.run_mount(mounted=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(args)


if __name__ == "__main__":
    unittest.main()
