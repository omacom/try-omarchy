#!/usr/bin/env python3
"""Run the patch's portable ICMP regression test without downloading libslirp."""
import hashlib
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

NATIVE = Path(__file__).resolve().parents[1]
PATCH = NATIVE / "patches/libslirp-darwin-icmp-matching.patch"


def added_file(name):
    lines = PATCH.read_text().splitlines(keepends=True)
    start = lines.index(f"+++ b/{name}\n") + 1
    result = []
    for line in lines[start:]:
        if line.startswith("--- "):
            break
        if line.startswith("@@"):
            continue
        if not line.startswith("+"):
            raise AssertionError(f"expected wholly added file {name}: {line!r}")
        result.append(line[1:])
    return "".join(result)


class ICMPPatchTests(unittest.TestCase):
    def test_portable_packet_matching(self):
        with tempfile.TemporaryDirectory(prefix="omarchy-icmp-test-") as temporary:
            root = Path(temporary)
            (root / "icmp-match.h").write_text(added_file("src/icmp-match.h"))
            source = root / "icmp-match-test.c"
            source.write_text(added_file("test/icmp-match-test.c"))
            binary = root / "icmp-match-test"
            subprocess.run(["cc", "-std=c99", "-Wall", "-Wextra", "-Werror",
                            str(source), "-o", str(binary)], check=True)
            subprocess.run([str(binary)], check=True)

    def test_patch_checksum_pin(self):
        script = (NATIVE / "build-qemu-gpu-runtime.sh").read_text()
        for variable, filename in (
            ("slirp_patch_sha256", "libslirp-darwin-icmp-matching.patch"),
            ("udp_patch_sha256", "libslirp-ipv4-udp-translation.patch"),
        ):
            with self.subTest(patch=filename):
                patch = NATIVE / "patches" / filename
                pin = re.search(rf"^{variable}=([0-9a-f]{{64}})$", script, re.M)
                self.assertIsNotNone(pin)
                self.assertEqual(pin.group(1), hashlib.sha256(patch.read_bytes()).hexdigest())



if __name__ == "__main__":
    unittest.main()
