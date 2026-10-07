#!/usr/bin/env python3
"""Checksum and compile the Cocoa minimum guest size, without AppKit."""

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
PATCH = ROOT / "macos/patches/qemu-cocoa-minimum-guest-size.patch"
DISPLAY_PATCH = ROOT / "macos/patches/qemu-cocoa-dynamic-display.patch"
BUILDER = ROOT / "macos/build-qemu-gpu-runtime.sh"


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


class CocoaMinimumGuestSizeTests(unittest.TestCase):
    def test_offered_size_never_drops_below_firmware_console(self) -> None:
        added = plus_lines()
        clamp = extract_c_block(
            added,
            "static NSSize cocoa_guest_frame_size(NSSize size, CGFloat scale)",
            "\n}",
        )
        # Both the windowed and the fullscreen size, and the zoom path, pass
        # through the clamp before the EDID density and mode are derived.
        self.assertIn(
            "frameSize = cocoa_guest_frame_size(\n"
            "            isFullscreen ? [self screenSafeAreaSize] : [self frame].size,\n"
            "            [[self window] backingScaleFactor]);",
            added,
        )
        self.assertIn("frameSize = cocoa_guest_frame_size([self frame].size, 1);", added)

        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / "minimum-size.c").write_text(
                f"""
#include <assert.h>
#include <math.h>

typedef double CGFloat;
typedef struct {{ CGFloat width; CGFloat height; }} NSSize;
#define MAX(a, b) ((a) > (b) ? (a) : (b))

static NSSize NSMakeSize(CGFloat width, CGFloat height)
{{
    NSSize size = {{ width, height }};
    return size;
}}

{clamp}

static void expect_pixels(NSSize points, CGFloat scale,
                          CGFloat width, CGFloat height)
{{
    NSSize offered = cocoa_guest_frame_size(points, scale);
    assert(offered.width * (scale > 0 ? scale : 1) >= width);
    assert(offered.height * (scale > 0 ? scale : 1) >= height);
}}

int main(void)
{{
    /* EDK2's graphics console needs 80x25 cells of 8x19 pixels. */
    expect_pixels(NSMakeSize(732, 412), 1, 800, 600);
    expect_pixels(NSMakeSize(22, 48), 2, 800, 600);
    expect_pixels(NSMakeSize(1, 1), 3, 800, 600);
    expect_pixels(NSMakeSize(10, 10), 0, 800, 600);
    expect_pixels(NSMakeSize(10, 10), -1, 800, 600);

    /* A window that is already large enough is offered unchanged. */
    NSSize large = cocoa_guest_frame_size(NSMakeSize(1512, 945), 2);
    assert(large.width == 1512 && large.height == 945);
    NSSize wide = cocoa_guest_frame_size(NSMakeSize(1200, 300), 1);
    assert(wide.width == 1200 && wide.height == 600);
    NSSize retina = cocoa_guest_frame_size(NSMakeSize(300, 200), 2);
    assert(retina.width == 400 && retina.height == 300);
    return 0;
}}
""",
                encoding="utf-8",
            )
            compiler = shlex.split(os.environ.get("CC", "cc"))
            binary = work / "minimum-size"
            subprocess.run(
                compiler
                + [
                    "-std=c11",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    str(work / "minimum-size.c"),
                    "-o",
                    str(binary),
                    "-lm",
                ],
                check=True,
            )
            subprocess.run([str(binary)], check=True)

    def test_patch_targets_the_dynamic_display_mode_source(self) -> None:
        display = DISPLAY_PATCH.read_text(encoding="utf-8")
        removed = [
            line[1:]
            for line in PATCH.read_text(encoding="utf-8").splitlines()
            if line.startswith("-") and not line.startswith("---")
        ]
        self.assertEqual(
            removed,
            [
                "        frameSize = isFullscreen ? [self screenSafeAreaSize] : [self frame].size;",
                "        frameSize = [self frame].size;",
            ],
        )
        self.assertIn("info.width_mm = 10 * MIN(255, MAX(1, (int)lround(", display)

    def test_builder_verifies_exact_patch_after_dynamic_display(self) -> None:
        builder = BUILDER.read_text(encoding="utf-8")
        expected = re.search(
            r"^minimum_guest_size_patch_sha256=([a-f0-9]{64})$", builder, re.M
        )
        self.assertIsNotNone(expected)
        self.assertEqual(
            hashlib.sha256(PATCH.read_bytes()).hexdigest(), expected.group(1)
        )
        apply = 'patch -d "$source_dir" -p1 -f -i "$minimum_guest_size_patch"'
        self.assertIn(apply, builder)
        self.assertLess(
            builder.index('patch -d "$source_dir" -p1 -f -i "$display_patch"'),
            builder.index(apply),
        )


if __name__ == "__main__":
    unittest.main()
