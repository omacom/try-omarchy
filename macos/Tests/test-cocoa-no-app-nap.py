#!/usr/bin/env python3
"""Checksum, place and compile the Cocoa App Nap activity, without QEMU."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "macos/patches/qemu-cocoa-no-app-nap.patch"
BUILDER = ROOT / "macos/build-qemu-gpu-runtime.sh"


def plus_lines() -> str:
    return "\n".join(
        line[1:]
        for line in PATCH.read_text(encoding="utf-8").splitlines()
        if line.startswith("+") and not line.startswith("+++")
    )


class CocoaNoAppNapTests(unittest.TestCase):
    def test_activity_is_held_before_the_run_loop(self) -> None:
        lines = PATCH.read_text(encoding="utf-8").splitlines()
        body = lines[next(i for i, line in enumerate(lines) if line.startswith("@@")) + 1:]
        self.assertEqual([line for line in body if line.startswith("-")], [])
        patched = "\n".join(line[1:] for line in body if line[:1] in (" ", "+"))
        self.assertIn(
            "static int cocoa_main(void)\n{\n    cocoa_hold_no_app_nap_activity();\n"
            "    COCOA_DEBUG(\"Main thread: entering OSX run loop\\n\");",
            patched,
        )
        # Idle system sleep stays allowed; the helper pauses the VM for sleep.
        added = plus_lines()
        self.assertIn("NSActivityUserInitiatedAllowingIdleSystemSleep", added)
        self.assertNotIn("NSActivityIdleSystemSleepDisabled", added)

    def test_activity_compiles_and_honours_the_opt_out(self) -> None:
        added = plus_lines()
        function = added[added.index("static void cocoa_hold_no_app_nap_activity(void)"):]
        function = function[: function.index("\n}\n") + 3]
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            source = work / "no-app-nap.m"
            source.write_text(
                f"""
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define info_report(...) (printf(__VA_ARGS__), printf("\\n"))

{function}

int main(void)
{{
    cocoa_hold_no_app_nap_activity();
    return 0;
}}
""",
                encoding="utf-8",
            )
            compiler = shlex.split(os.environ.get("CC", "cc"))
            binary = work / "no-app-nap"
            subprocess.run(
                compiler + ["-fno-objc-arc", "-Wall", "-Wextra", "-Werror", str(source),
                            "-framework", "Foundation", "-o", str(binary)],
                check=True,
            )
            environment = {key: value for key, value in os.environ.items() if key != "TRYOMARCHY_APP_NAP"}
            held = subprocess.run([str(binary)], capture_output=True, text=True, check=True, env=environment)
            self.assertEqual(held.stdout.strip(), "Try Omarchy: App Nap off while the VM runs")
            allowed = subprocess.run([str(binary)], capture_output=True, text=True, check=True,
                                     env={**environment, "TRYOMARCHY_APP_NAP": "1"})
            self.assertEqual(allowed.stdout.strip(), "Try Omarchy: App Nap allowed (TRYOMARCHY_APP_NAP=1)")

    def test_builder_verifies_exact_patch_after_cocoa_patches(self) -> None:
        builder = BUILDER.read_text(encoding="utf-8")
        expected = re.search(r"^no_app_nap_patch_sha256=([a-f0-9]{64})$", builder, re.M)
        self.assertIsNotNone(expected)
        self.assertEqual(hashlib.sha256(PATCH.read_bytes()).hexdigest(), expected.group(1))
        apply = 'patch -d "$source_dir" -p1 -f -i "$no_app_nap_patch"'
        # After every other Cocoa patch: its context is their cocoa_main.
        cocoa = re.findall(r'^patch -d "\$source_dir" -p1 -f -i "\$([a-z_]+)"$', builder, re.M)
        position = cocoa.index("no_app_nap_patch")
        self.assertGreater(position, cocoa.index("minimum_guest_size_patch"))
        self.assertIn(apply, builder)


if __name__ == "__main__":
    unittest.main()
