#!/usr/bin/env python3
"""Checksum and compile the Cocoa ISO Section/Grave swap, without AppKit."""

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
PATCH = ROOT / "macos/patches/qemu-cocoa-iso-section-grave-swap.patch"
BUILDER = ROOT / "macos/build-qemu-gpu-runtime.sh"
RUNNER = ROOT / "macos/run-qemu-gpu.sh"
KEY_GRAVE = 41
KEY_102ND = 86


def plus_lines() -> str:
    return "\n".join(
        line[1:]
        for line in PATCH.read_text(encoding="utf-8").splitlines()
        if line.startswith("+") and not line.startswith("+++")
    )


def extract_c_block(source: str, start: str, end: str) -> str:
    begin = source.index(start)
    finish = source.index(end, begin) + len(end)
    return source[begin:finish]


class CocoaIsoKeyboardTests(unittest.TestCase):
    def test_iso_swap_compiles_and_only_swaps_when_env_is_iso(self) -> None:
        added = plus_lines()
        probe = extract_c_block(
            added,
            "static int cocoa_iso_swap_cached = -1;",
            "    return false;\n}",
        )
        swap = extract_c_block(
            added,
            "    if (cocoa_host_keyboard_is_iso()) {",
            "        }\n    }",
        )
        self.assertIn('strcmp(geometry, "iso") == 0', probe)
        self.assertNotIn("KBGetLayoutType", added)
        self.assertLess(added.index("linux_keycode == KEY_GRAVE"), added.index("return KEY_102ND;"))
        self.assertLess(added.index("return KEY_102ND;"), added.index("linux_keycode == KEY_102ND"))

        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / "iso-swap.c").write_text(
                f"""
#include <assert.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#define KEY_GRAVE {KEY_GRAVE}
#define KEY_102ND {KEY_102ND}

{probe}

static int apply_iso_swap(int linux_keycode)
{{
{swap}
    return linux_keycode;
}}

int main(void)
{{
    const char *expect = getenv("TRYOMARCHY_ISO_EXPECT");
    int grave = apply_iso_swap(KEY_GRAVE);
    int iso = apply_iso_swap(KEY_102ND);
    int other = apply_iso_swap(30);
    if (expect && strcmp(expect, "swap") == 0) {{
        assert(grave == KEY_102ND);
        assert(iso == KEY_GRAVE);
    }} else {{
        assert(grave == KEY_GRAVE);
        assert(iso == KEY_102ND);
    }}
    assert(other == 30);
    return 0;
}}
""",
                encoding="utf-8",
            )
            compiler = shlex.split(os.environ.get("CC", "cc"))
            binary = work / "iso-swap"
            subprocess.run(
                compiler
                + ["-std=c11", "-Wall", "-Wextra", "-Werror", str(work / "iso-swap.c"), "-o", str(binary)],
                check=True,
            )
            cases = (
                ({"TRYOMARCHY_KEYBOARD": "iso", "TRYOMARCHY_ISO_EXPECT": "swap"},),
                ({"TRYOMARCHY_KEYBOARD": "ansi", "TRYOMARCHY_ISO_EXPECT": "keep"},),
                ({"TRYOMARCHY_KEYBOARD": "jis", "TRYOMARCHY_ISO_EXPECT": "keep"},),
                ({"TRYOMARCHY_KEYBOARD": "", "TRYOMARCHY_ISO_EXPECT": "keep"},),
                ({"TRYOMARCHY_ISO_EXPECT": "keep"},),
            )
            for (env,) in cases:
                completed = subprocess.run(
                    [str(binary)],
                    check=False,
                    env={**os.environ, **env},
                )
                self.assertEqual(completed.returncode, 0, env)

    def test_builder_verifies_exact_patch(self) -> None:
        builder = BUILDER.read_text(encoding="utf-8")
        expected = re.search(r"^iso_swap_patch_sha256=([a-f0-9]{64})$", builder, re.M)
        self.assertIsNotNone(expected)
        self.assertEqual(
            hashlib.sha256(PATCH.read_bytes()).hexdigest(), expected.group(1)
        )
        self.assertIn(
            'patch -d "$source_dir" -p1 -f -i "$iso_swap_patch"',
            builder,
        )

    def test_runner_exports_helper_geometry(self) -> None:
        runner = RUNNER.read_text(encoding="utf-8")
        self.assertIn("--host-keyboard-geometry", runner)
        self.assertIn(
            'keyboard_kernel_argument=" tryomarchy.keyboard=$host_keyboard_geometry"',
            runner,
        )
        self.assertIn("export TRYOMARCHY_KEYBOARD=$host_keyboard_geometry", runner)
        self.assertNotIn("/usr/bin/swift", runner)


if __name__ == "__main__":
    unittest.main()
