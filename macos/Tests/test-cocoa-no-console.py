#!/usr/bin/env python3
"""Start the Cocoa display without a console, as pristine QEMU allows."""

import hashlib
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "macos/patches/qemu-texture-borrowing-11.1.patch"
START = "dcl.con = qemu_console_lookup_default();"
END = "// Create an Application controller"


def patched_cocoa_hunks():
    section = PATCH.read_text().split(
        "diff --color -urN pristine/src/ui/cocoa.m trim/src/ui/cocoa.m\n", 1
    )[1].split("\ndiff --color ", 1)[0]
    return ["\n".join(line[1:] for line in hunk.splitlines()
                      if line.startswith((" ", "+")))
            for hunk in re.split(r"^@@.*@@.*$", section, flags=re.M)[1:]]


class CocoaNoConsoleTests(unittest.TestCase):
    def test_build_uses_verified_patch(self):
        builder = (ROOT / "macos/build-qemu-gpu-runtime.sh").read_text()
        digest = hashlib.sha256(PATCH.read_bytes()).hexdigest()
        self.assertIn(f"texture_patch_sha256={digest}", builder)
        self.assertIn('"$texture_patch" "$texture_patch_sha256"', builder)
        self.assertIn('patch -d "$source_dir" -p1 -f -i "$texture_patch"', builder)

    def test_startup_without_console(self):
        # Compile the patched statements that run before the controller is
        # created. With no console they must not reach qemu_console_surface();
        # QEMU's listener registration later shows its placeholder surface.
        hunks = patched_cocoa_hunks()
        startup = [hunk for hunk in hunks if START in hunk]
        self.assertEqual(len(startup), 1, "console lookup must be in one hunk")
        startup = START + startup[0].split(START, 1)[1]
        self.assertIn(END, startup)
        startup = startup.split(END, 1)[0]
        source = "\n".join(hunks)
        self.assertEqual(source.count("qemu_console_surface("),
                         startup.count("qemu_console_surface("), "surface read moved")
        self.assertIn("qemu_console_register_listener(qemu_console_lookup_default(),",
                      source)
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            harness = (ROOT / "macos/Tests/cocoa-no-console-harness.c").read_text()
            (work / "test.c").write_text(harness.replace("/* STARTUP */", startup))
            compiler = shlex.split(os.environ.get("CC", "cc"))
            subprocess.run(compiler + ["-std=c11", "-Wall", "-Wextra", "-Werror",
                           str(work / "test.c"), "-o", str(work / "test")], check=True)
            subprocess.run([str(work / "test")], check=True)


if __name__ == "__main__":
    unittest.main()
