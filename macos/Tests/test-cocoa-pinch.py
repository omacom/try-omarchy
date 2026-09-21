#!/usr/bin/env python3
"""Compile and exercise the geometry shipped in the QEMU patch, without AppKit."""

import hashlib
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "macos/patches/qemu-cocoa-pinch-zoom.patch"


def added_file(path):
    section = PATCH.read_text().split(f"diff --git a/{path} b/{path}\n", 1)[1]
    section = section.split("\ndiff --git ", 1)[0]
    return "".join(line[1:] + "\n" for line in section.splitlines()
                   if line.startswith("+") and not line.startswith("+++"))


class CocoaPinchTests(unittest.TestCase):
    def test_geometry_and_lifecycle(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / "cocoa-pinch.h").write_text(added_file("include/ui/cocoa-pinch.h"))
            (work / "test.c").write_text(r'''
#include <assert.h>
#include <float.h>
#include "cocoa-pinch.h"

static CocoaPinchFrame frames[16];
static unsigned count;

static void record(void *opaque, const CocoaPinchFrame *frame)
{
    assert(opaque == frames);
    assert(count < 16);
    frames[count++] = *frame;
}

static void check_bounds(const CocoaPinch *pinch)
{
    int left = cocoa_pinch_x(pinch, 0);
    int right = cocoa_pinch_x(pinch, 1);
    assert(left >= 0 && right <= COCOA_PINCH_AXIS_MAX);
    assert(left < right);
    assert(left + right == 2 * COCOA_PINCH_CENTER);
}

int main(void)
{
    CocoaPinch pinch = {0};
    assert(!cocoa_pinch_update(&pinch, 0.5));
    assert(!cocoa_pinch_end(&pinch));

    cocoa_pinch_begin(&pinch);
    assert(pinch.active && pinch.scale == 1.0);
    int original = cocoa_pinch_x(&pinch, 1) - cocoa_pinch_x(&pinch, 0);
    assert(cocoa_pinch_update(&pinch, 0.5));
    int expanded = cocoa_pinch_x(&pinch, 1) - cocoa_pinch_x(&pinch, 0);
    assert(expanded == original * 3 / 2);
    assert(cocoa_pinch_update(&pinch, -1.0 / 3.0));
    assert(fabs(pinch.scale - 1.0) < 1e-12);
    check_bounds(&pinch);

    /* Small events accumulate continuously instead of becoming key presses. */
    for (int i = 0; i < 100; i++) {
        assert(cocoa_pinch_update(&pinch, 0.001));
        check_bounds(&pinch);
    }
    assert(fabs(pinch.scale - pow(1.001, 100)) < 1e-12);

    /* Extreme finite input saturates; non-finite/invalid deltas are rejected. */
    assert(cocoa_pinch_update(&pinch, DBL_MAX));
    check_bounds(&pinch);
    assert(cocoa_pinch_update(&pinch, DBL_MAX));
    check_bounds(&pinch);
    for (int i = 0; i < 100; i++) {
        assert(cocoa_pinch_update(&pinch, -0.9));
        check_bounds(&pinch);
    }
    double before = pinch.scale;
    assert(!cocoa_pinch_update(&pinch, NAN));
    assert(!cocoa_pinch_update(&pinch, INFINITY));
    assert(!cocoa_pinch_update(&pinch, -INFINITY));
    assert(!cocoa_pinch_update(&pinch, -1.0));
    assert(!cocoa_pinch_update(&pinch, -2.0));
    assert(pinch.scale == before);

    /* End/cancel/focus loss emit one release, and orphaned updates stay idle. */
    assert(cocoa_pinch_end(&pinch));
    assert(!cocoa_pinch_end(&pinch));
    assert(!cocoa_pinch_update(&pinch, 0.1));
    cocoa_pinch_begin(&pinch);
    assert(pinch.scale == 1.0);
    assert(cocoa_pinch_end(&pinch));

    /* Exercise the same lifecycle dispatch used by the Cocoa event handler. */
    assert(cocoa_pinch_event(&pinch, 0, true, 0.5, record, frames));
    assert(count == 0);  /* orphaned update */
    assert(!cocoa_pinch_event(&pinch, COCOA_PINCH_BEGIN, false, 0.1,
                             record, frames));
    assert(count == 0);  /* background window */
    cocoa_pinch_event(&pinch, COCOA_PINCH_BEGIN, true, 0, record, frames);
    assert(count == 1 && frames[0].down);
    cocoa_pinch_event(&pinch, 0, true, 0.5, record, frames);
    assert(count == 2 && frames[1].down);
    assert(frames[1].x[1] > frames[0].x[1]);
    cocoa_pinch_event(&pinch, COCOA_PINCH_END, true, 0, record, frames);
    assert(count == 3 && !frames[2].down);
    cocoa_pinch_event(&pinch, COCOA_PINCH_END, true, 0, record, frames);
    assert(count == 3);

    cocoa_pinch_event(&pinch, COCOA_PINCH_BEGIN, true, 0, record, frames);
    assert(frames[3].x[1] == frames[0].x[1]);
    cocoa_pinch_cancel(&pinch, record, frames);  /* windowDidResignKey */
    assert(count == 5 && !frames[4].down);
    cocoa_pinch_event(&pinch, 0, true, 0.5, record, frames);
    assert(count == 5);  /* focus return does not resume old contacts */

    cocoa_pinch_event(&pinch, COCOA_PINCH_BEGIN, true, 0, record, frames);
    cocoa_pinch_event(&pinch, COCOA_PINCH_CANCEL, true, 0.5, record, frames);
    assert(count == 7 && !frames[6].down);
    cocoa_pinch_event(&pinch, COCOA_PINCH_BEGIN, true, NAN, record, frames);
    assert(count == 7);  /* invalid begin never creates contacts */
    cocoa_pinch_event(&pinch, COCOA_PINCH_BEGIN, true, 0, record, frames);
    cocoa_pinch_event(&pinch, 0, true, NAN, record, frames);
    assert(count == 9 && !frames[8].down);  /* invalid update releases */
    cocoa_pinch_event(&pinch, COCOA_PINCH_BEGIN, true, 0, record, frames);
    cocoa_pinch_event(&pinch, 0, false, 0, record, frames);
    assert(count == 11 && !frames[10].down);  /* pointer leaves guest */
    cocoa_pinch_event(&pinch, COCOA_PINCH_BEGIN, true, 0, record, frames);
    cocoa_pinch_vm_state(&pinch, false, record, frames);
    assert(count == 12 && !pinch.active);  /* no input while stopped */
    cocoa_pinch_cancel(&pinch, record, frames);  /* focus loss while stopped */
    cocoa_pinch_vm_state(&pinch, true, record, frames);
    assert(count == 13 && !frames[12].down);  /* clear guest slots on resume */
    cocoa_pinch_event(&pinch, 0, true, 0.2, record, frames);
    assert(count == 13);
    return 0;
}
''')
            compiler = shlex.split(os.environ.get("CC", "cc"))
            subprocess.run(compiler + ["-std=c11", "-Wall", "-Wextra", "-Werror",
                           str(work / "test.c"), "-lm", "-o", str(work / "test")],
                           check=True)
            subprocess.run([str(work / "test")], check=True)

    def test_builder_verifies_exact_patch(self):
        builder = (ROOT / "macos/build-qemu-gpu-runtime.sh").read_text()
        expected = re.search(r"^pinch_patch_sha256=([a-f0-9]{64})$", builder, re.M)
        self.assertIsNotNone(expected)
        self.assertEqual(hashlib.sha256(PATCH.read_bytes()).hexdigest(), expected[1])


if __name__ == "__main__":
    unittest.main()
