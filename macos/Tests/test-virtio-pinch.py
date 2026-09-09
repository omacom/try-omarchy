#!/usr/bin/env python3
"""Optional guest-ABI test against a patched x86_64 QEMU built on Linux.

QEMU_PINCH_TEST_BINARY=/path/to/qemu-system-x86_64 python3 this-file.py
Uses qtest, with no guest disk, host input injection, or hardware acceleration.
"""

import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest


BINARY = os.environ.get("QEMU_PINCH_TEST_BINARY")


@unittest.skipUnless(BINARY, "set QEMU_PINCH_TEST_BINARY to run the guest ABI test")
class VirtioPinchTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        work = Path(self.directory.name)
        self.log = open(work / "qemu.log", "w+")
        self.addCleanup(self.log.close)
        # qtest does not execute guest instructions; provide an inert ROM.
        (work / "bios").write_bytes(bytes(65536))
        self.process = subprocess.Popen([
            BINARY, "-machine", "q35", "-accel", "qtest", "-m", "64M",
            "-nodefaults", "-display", "none", "-S", "-bios", str(work / "bios"),
            "-device", "virtio-tablet-pci,addr=03.0,romfile=",
            "-device", "virtio-pinch-pci,addr=04.0,romfile=",
            "-qtest", f"unix:{work}/qtest,server=on,wait=off",
            "-qmp", f"unix:{work}/qmp,server=on,wait=off",
        ], stdout=self.log, stderr=self.log)
        self.addCleanup(self.stop)
        self.qtest = self.connect(work / "qtest")
        self.qmp = self.connect(work / "qmp")
        json.loads(self.qmp.readline())
        self.command("qmp_capabilities")
        self.bar = 0x10000000
        cap = self.pci_read(0x34) & 0xff
        self.caps = {}
        seen = set()
        while cap:
            self.assertNotIn(cap, seen)
            seen.add(cap)
            header = self.pci_read(cap)
            if header & 0xff == 9 and header >> 24 in (1, 2, 3, 4):
                kind = header >> 24
                bar = self.pci_read(cap + 4) & 0xff
                self.assertEqual(bar, 4)
                self.caps[kind] = self.bar + self.pci_read(cap + 8)
            cap = (header >> 8) & 0xff
        self.pci_write(0x20, self.bar)  # BAR4 (64 bit)
        self.pci_write(0x24, 0)
        self.pci_write(0x04, 6)  # memory + bus master
        self.assertIn(1, self.caps)
        self.assertIn(4, self.caps)

    def stop(self):
        if self.process.poll() not in (None, 0):
            self.log.seek(0)
            print(self.log.read(), file=sys.stderr)
        self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)

    def connect(self, path):
        sock = socket.socket(socket.AF_UNIX)
        self.addCleanup(sock.close)
        sock.settimeout(5)
        deadline = time.monotonic() + 5
        while True:
            try:
                sock.connect(str(path))
                break
            except (FileNotFoundError, ConnectionRefusedError):
                if self.process.poll() is not None or time.monotonic() > deadline:
                    self.log.seek(0)
                    self.fail(self.log.read())
                time.sleep(0.01)
        stream = sock.makefile("rwb", buffering=0)
        self.addCleanup(stream.close)
        return stream

    def qt(self, line):
        self.qtest.write((line + "\n").encode())
        while True:
            reply = self.qtest.readline().decode().strip()
            if not reply.startswith("IRQ"):
                self.assertTrue(reply.startswith("OK"), reply)
                return reply[2:].strip()

    def command(self, name, arguments=None):
        self.qmp.write((json.dumps({"execute": name, "arguments": arguments or {}})
                        + "\n").encode())
        while True:
            reply = json.loads(self.qmp.readline())
            if "event" not in reply:
                self.assertNotIn("error", reply)
                return reply.get("return")

    def pci_read(self, offset):
        self.qt(f"outl 0xcf8 {0x80002000 + offset:#x}")
        return int(self.qt("inl 0xcfc"), 0)

    def pci_write(self, offset, value):
        self.qt(f"outl 0xcf8 {0x80002000 + offset:#x}")
        self.qt(f"outl 0xcfc {value:#x}")

    def write(self, address, data):
        self.qt(f"write {address:#x} {len(data):#x} 0x{data.hex()}")

    def read(self, address, length):
        return bytes.fromhex(self.qt(f"read {address:#x} {length:#x}")[2:])

    def config(self, select, subselect=0):
        address = self.caps[4]
        self.qt(f"writeb {address:#x} {select}")
        self.qt(f"writeb {address + 1:#x} {subselect}")
        size = int(self.qt(f"readb {address + 2:#x}"), 0)
        return self.read(address + 8, size) if size else b""

    def test_touchpad_capabilities_and_contact_frames(self):
        self.assertEqual(self.config(1).rstrip(b"\0"), b"QEMU Virtio Pinch Touchpad")
        self.assertEqual(int.from_bytes(self.config(0x10), "little"), 1)  # POINTER
        keys = int.from_bytes(self.config(0x11, 1), "little")
        for key in (0x110, 0x145, 0x14a, 0x14d):  # LEFT, FINGER, TOUCH, DOUBLETAP
            self.assertTrue(keys & (1 << key))
        axes = int.from_bytes(self.config(0x11, 3), "little")
        for axis in (0, 1, 0x2f, 0x35, 0x36, 0x39):
            self.assertTrue(axes & (1 << axis))
        for axis in (0, 1, 0x35, 0x36):
            self.assertEqual(struct.unpack("<5I", self.config(0x12, axis)),
                             (0, 32767, 0, 0, 327))

        common = self.caps[1]
        self.qt(f"writeb {common + 20:#x} 3")
        self.qt(f"writel {common + 8:#x} 1")
        self.qt(f"writel {common + 12:#x} 1")  # VIRTIO_F_VERSION_1
        self.qt(f"writeb {common + 20:#x} 11")
        self.assertEqual(int(self.qt(f"readb {common + 20:#x}"), 0), 11)
        self.qt(f"writew {common + 22:#x} 0")
        self.qt(f"writew {common + 24:#x} 64")
        desc, avail, used, buffers = 0x100000, 0x101000, 0x102000, 0x103000
        self.write(desc, b"".join(struct.pack("<QIHH", buffers + i * 8, 8, 2, 0)
                                  for i in range(64)))
        self.write(avail, struct.pack("<66H", 0, 64, *range(64)))
        for offset, address in ((32, desc), (40, avail), (48, used)):
            self.qt(f"writeq {common + offset:#x} {address:#x}")
        self.qt(f"writew {common + 28:#x} 1")
        self.qt(f"writeb {common + 20:#x} 15")
        self.command("cont")

        def contact(kind, slot, tracking, axis="x", value=0):
            return {"type": "mtt", "data": {"type": kind, "slot": slot,
                    "tracking-id": tracking, "axis": axis, "value": value}}

        def frame(radius):
            events = []
            for slot in range(2):
                events += [contact("update", slot, slot),
                           contact("data", slot, slot, "x", 16384 + (2 * slot - 1) * radius),
                           contact("data", slot, slot, "y", 16384)]
            return events

        self.command("input-send-event", {"events": frame(4096)})
        self.command("input-send-event", {"events": frame(6144)})
        self.command("input-send-event", {"events": [contact("end", 0, -1),
                                                       contact("end", 1, -1)]})
        count = struct.unpack("<H", self.read(used + 2, 2))[0]
        self.assertEqual(count, 33)  # two motion frames (13 each), release (7)
        events = [struct.unpack("<HHi", self.read(buffers + i * 8, 8))
                  for i in range(count)]
        self.assertEqual(events[:2], [(1, 0x14a, 1), (1, 0x14d, 1)])
        self.assertEqual(events[-7:], [(1, 0x14a, 0), (1, 0x14d, 0),
                         (3, 0x2f, 0), (3, 0x39, -1), (3, 0x2f, 1),
                         (3, 0x39, -1), (0, 0, 0)])
        # Normal mouse buttons must still route to the tablet, not this device.
        self.command("input-send-event", {"events": [
            {"type": "btn", "data": {"button": "left", "down": True}},
            {"type": "btn", "data": {"button": "left", "down": False}},
        ]})
        self.assertEqual(struct.unpack("<H", self.read(used + 2, 2))[0], count)


if __name__ == "__main__":
    unittest.main()
