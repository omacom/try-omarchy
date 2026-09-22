#!/usr/bin/env python3
"""Exercise precise-scroll accumulation and its QEMU integration contract."""

import hashlib
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "macos/patches/qemu-cocoa-precise-scroll.patch"


def added_file(path):
    section = PATCH.read_text().split(f"diff --git a/{path} b/{path}\n", 1)[1]
    section = section.split("\ndiff --git ", 1)[0]
    return "".join(line[1:] + "\n" for line in section.splitlines()
                   if line.startswith("+") and not line.startswith("+++"))


class CocoaScrollTests(unittest.TestCase):
    def test_discrete_wheel_after_precise_scroll(self):
        # Compile the actual patched BTN/REL dispatch, with only QEMU's device
        # and transport interfaces stubbed. Keep the cases in one patch hunk
        # so missing context cannot silently change the code under test.
        section = PATCH.read_text().split(
            "diff --git a/hw/input/virtio-input-hid.c "
            "b/hw/input/virtio-input-hid.c\n", 1
        )[1].split("\ndiff --git ", 1)[0]
        cases = None
        for hunk in re.split(r"^@@.*@@.*$", section, flags=re.M)[1:]:
            source = "\n".join(line[1:] for line in hunk.splitlines()
                               if line.startswith((" ", "+")))
            if ("case INPUT_EVENT_KIND_BTN:" in source and
                    "case INPUT_EVENT_KIND_ABS:" in source):
                cases = source.split("case INPUT_EVENT_KIND_BTN:", 1)[1]
                cases = "case INPUT_EVENT_KIND_BTN:" + cases.split(
                    "case INPUT_EVENT_KIND_ABS:", 1)[0]
                break
        self.assertIsNotNone(cases, "wheel dispatch must be a complete patch hunk")
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            harness = (ROOT / "macos/Tests/virtio-scroll-harness.c").read_text()
            (work / "test.c").write_text(harness.replace("/* WHEEL_DISPATCH */", cases))
            compiler = shlex.split(os.environ.get("CC", "cc"))
            subprocess.run(compiler + ["-std=c11", "-Wall", "-Wextra", "-Werror",
                           str(work / "test.c"), "-o", str(work / "test")], check=True)
            subprocess.run([str(work / "test")], check=True)

    def test_fractional_deltas_are_retained(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / "cocoa-scroll.h").write_text(
                added_file("include/ui/cocoa-scroll.h")
            )
            (work / "test.c").write_text(r'''
#include <assert.h>
#include <limits.h>
#include <math.h>
#include "cocoa-scroll.h"

int main(void)
{
    CocoaScroll scroll = {0};
    CocoaScrollFrame frame;
    int total = 0;

    /* Sub-point events are not promoted to full wheel clicks or discarded. */
    for (int i = 0; i < 8; i++) {
        frame = cocoa_scroll_update(&scroll, 0.0, 0.25);
        total += frame.y;
    }
    assert(total == 2);
    assert(fabs(scroll.residual_y) < 1e-12);

    /* Direction changes preserve the exact accumulated distance. */
    frame = cocoa_scroll_update(&scroll, 0.75, -0.75);
    assert(frame.x == 0 && frame.y == 0);
    frame = cocoa_scroll_update(&scroll, 0.50, -0.50);
    assert(frame.x == 1 && frame.y == -1);
    assert(fabs(scroll.residual_x - 0.25) < 1e-12);
    assert(fabs(scroll.residual_y + 0.25) < 1e-12);

    /* Momentum is just another precise delta stream; no artificial reset. */
    frame = cocoa_scroll_update(&scroll, 0.0, -0.75);
    assert(frame.y == -1);
    assert(fabs(scroll.residual_y) < 1e-12);

    cocoa_scroll_cancel(&scroll);
    assert(scroll.residual_x == 0.0 && scroll.residual_y == 0.0);

    frame = cocoa_scroll_update(&scroll, NAN, INFINITY);
    assert(frame.x == 0 && frame.y == 0);
    assert(scroll.residual_x == 0.0 && scroll.residual_y == 0.0);

    frame = cocoa_scroll_update(&scroll, (double)INT_MAX * 2.0,
                                (double)INT_MIN * 2.0);
    assert(frame.x == INT_MAX && frame.y == INT_MIN);
    return 0;
}
''')
            compiler = shlex.split(os.environ.get("CC", "cc"))
            subprocess.run(compiler + ["-std=c11", "-Wall", "-Wextra", "-Werror",
                           str(work / "test.c"), "-lm", "-o", str(work / "test")],
                           check=True)
            subprocess.run([str(work / "test")], check=True)

    def test_transport_contract(self):
        source = PATCH.read_text()
        self.assertIn("[event hasPreciseScrollingDeltas]", source)
        self.assertIn("[event scrollingDeltaX]", source)
        self.assertIn("[event scrollingDeltaY]", source)
        self.assertIn("[event phase]", source)
        self.assertIn("[event momentumPhase]", source)
        self.assertIn("REL_WHEEL_HI_RES", source)
        self.assertIn("REL_HWHEEL_HI_RES", source)
        self.assertIn("total / 120", source)
        self.assertIn("Preserve discrete mouse-wheel behavior exactly", source)
        self.assertNotIn("cocoa_pinch_update(&pinch", source)

    def test_builder_verifies_exact_patch(self):
        builder = (ROOT / "macos/build-qemu-gpu-runtime.sh").read_text()
        expected = re.search(
            r"^precise_scroll_patch_sha256=([a-f0-9]{64})$", builder, re.M
        )
        self.assertIsNotNone(expected)
        self.assertEqual(hashlib.sha256(PATCH.read_bytes()).hexdigest(), expected[1])
        self.assertIn('patch -d "$source_dir" -p1 -f -i "$precise_scroll_patch"', builder)


if __name__ == "__main__":
    unittest.main()
