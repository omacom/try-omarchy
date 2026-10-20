#!/usr/bin/env python3
"""Exercise trackpad scrolling as touchpad contacts, from the shipped QEMU patch."""

import hashlib
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "macos/patches/qemu-cocoa-touch-scroll.patch"


def added_file(path):
    section = PATCH.read_text().split(f"diff --git a/{path} b/{path}\n", 1)[1]
    section = section.split("\ndiff --git ", 1)[0]
    return "".join(line[1:] + "\n" for line in section.splitlines()
                   if line.startswith("+") and not line.startswith("+++"))


def added_lines(path):
    section = PATCH.read_text().split(f"diff --git a/{path} b/{path}\n", 1)[1]
    section = section.split("\ndiff --git ", 1)[0]
    return "\n".join(line[1:] for line in section.splitlines()
                     if line.startswith("+") and not line.startswith("+++"))


class CocoaTouchScrollTests(unittest.TestCase):
    def test_contacts_and_lifecycle(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / "cocoa-touch-scroll.h").write_text(
                added_file("include/ui/cocoa-touch-scroll.h"))
            (work / "test.c").write_text(r'''
#include <assert.h>
#include <float.h>
#include "cocoa-touch-scroll.h"

static CocoaTouchScrollFrame frames[32];
static unsigned count;

static void record(void *opaque, const CocoaTouchScrollFrame *frame)
{
    assert(opaque == frames);
    assert(count < 32);
    frames[count++] = *frame;
    if (frame->down) {
        assert(frame->x[0] >= 4096 && frame->x[1] <= COCOA_TOUCH_SCROLL_AXIS_MAX - 4096);
        assert(frame->x[1] - frame->x[0] == 2 * COCOA_TOUCH_SCROLL_SPREAD);
        assert(frame->y >= COCOA_TOUCH_SCROLL_MIN && frame->y <= COCOA_TOUCH_SCROLL_MAX);
    }
}

static int center(const CocoaTouchScrollFrame *frame)
{
    return (frame->x[0] + frame->x[1]) / 2;
}

int main(void)
{
    CocoaTouchScroll s = { .units_per_point = 5.0 };

    assert(cocoa_touch_scroll_units_per_point(NULL) == 5.0);
    assert(cocoa_touch_scroll_units_per_point("") == 5.0);
    assert(cocoa_touch_scroll_units_per_point("2") == 10.0);
    assert(cocoa_touch_scroll_units_per_point("0.5") == 2.5);
    assert(cocoa_touch_scroll_units_per_point("fast") == 5.0);
    assert(cocoa_touch_scroll_units_per_point("2x") == 5.0);
    assert(cocoa_touch_scroll_units_per_point("0.01") == 5.0);
    assert(cocoa_touch_scroll_units_per_point("11") == 5.0);
    assert(cocoa_touch_scroll_units_per_point("nan") == 5.0);

    /* A scroll that began elsewhere, or outside the view, stays on the wheel. */
    assert(!cocoa_touch_scroll_event(&s, 0, true, 1, 1, record, frames));
    assert(!cocoa_touch_scroll_event(&s, COCOA_TOUCH_SCROLL_BEGIN, false, 0, 0,
                                     record, frames));
    assert(count == 0);

    /* Begin places both contacts at the center; Cocoa's +y lifts the fingers. */
    assert(cocoa_touch_scroll_event(&s, COCOA_TOUCH_SCROLL_BEGIN, true, 0, 0,
                                    record, frames));
    assert(count == 1 && frames[0].down);
    assert(center(&frames[0]) == COCOA_TOUCH_SCROLL_CENTER);
    assert(frames[0].y == COCOA_TOUCH_SCROLL_CENTER);
    assert(cocoa_touch_scroll_event(&s, 0, true, 0, 10, record, frames));
    assert(count == 2 && frames[1].down);
    assert(frames[1].y == COCOA_TOUCH_SCROLL_CENTER - 50);
    assert(center(&frames[1]) == COCOA_TOUCH_SCROLL_CENTER);
    assert(cocoa_touch_scroll_event(&s, 0, true, -4, 0, record, frames));
    assert(center(&frames[2]) == COCOA_TOUCH_SCROLL_CENTER + 20);

    /* Fractional points accumulate in sensor units, not per event. */
    for (int i = 0; i < 10; i++) {
        cocoa_touch_scroll_event(&s, 0, true, 0, -0.1, record, frames);
        count = 3;
    }
    assert(fabs(s.y - (COCOA_TOUCH_SCROLL_CENTER - 45)) < 1e-9);

    /* Zero deltas emit nothing; end releases once and returns ownership. */
    assert(cocoa_touch_scroll_event(&s, 0, true, 0, 0, record, frames));
    assert(count == 3);
    assert(cocoa_touch_scroll_event(&s, COCOA_TOUCH_SCROLL_END, true, 0, 0,
                                    record, frames));
    assert(count == 4 && !frames[3].down);
    assert(!cocoa_touch_scroll_event(&s, 0, true, 0, 5, record, frames));
    assert(count == 4);

    /* Deltas carried by the end event move before the release. */
    cocoa_touch_scroll_event(&s, COCOA_TOUCH_SCROLL_BEGIN, true, 0, 0, record, frames);
    cocoa_touch_scroll_event(&s, COCOA_TOUCH_SCROLL_END, true, 2, 0, record, frames);
    assert(count == 7 && frames[5].down && !frames[6].down);
    assert(center(&frames[5]) == COCOA_TOUCH_SCROLL_CENTER - 10);

    /* Cancel, focus loss, leaving the view and invalid deltas release. */
    cocoa_touch_scroll_event(&s, COCOA_TOUCH_SCROLL_BEGIN, true, 0, 0, record, frames);
    assert(cocoa_touch_scroll_event(&s, COCOA_TOUCH_SCROLL_CANCEL, true, 0, 0,
                                    record, frames));
    assert(count == 9 && !frames[8].down);
    cocoa_touch_scroll_event(&s, COCOA_TOUCH_SCROLL_BEGIN, true, 0, 0, record, frames);
    cocoa_touch_scroll_cancel(&s, record, frames);
    assert(count == 11 && !frames[10].down);
    cocoa_touch_scroll_cancel(&s, record, frames);
    assert(count == 11);
    cocoa_touch_scroll_event(&s, COCOA_TOUCH_SCROLL_BEGIN, true, 0, 0, record, frames);
    assert(!cocoa_touch_scroll_event(&s, 0, false, 0, 3, record, frames));
    assert(count == 13 && !frames[12].down);
    cocoa_touch_scroll_event(&s, COCOA_TOUCH_SCROLL_BEGIN, true, 0, 0, record, frames);
    assert(!cocoa_touch_scroll_event(&s, 0, true, NAN, 0, record, frames));
    assert(count == 15 && !frames[14].down);
    assert(!cocoa_touch_scroll_event(&s, COCOA_TOUCH_SCROLL_BEGIN, true, 0, INFINITY,
                                     record, frames));
    assert(count == 15 && !s.active);

    /* A new begin replaces stale contacts with a release first. */
    cocoa_touch_scroll_event(&s, COCOA_TOUCH_SCROLL_BEGIN, true, 0, 0, record, frames);
    cocoa_touch_scroll_event(&s, COCOA_TOUCH_SCROLL_BEGIN, true, 0, 0, record, frames);
    assert(count == 18 && frames[15].down && !frames[16].down && frames[17].down);

    /* Reaching an edge lifts and lands again on the far side of that axis. */
    count = 0;
    int travel = (COCOA_TOUCH_SCROLL_MAX - COCOA_TOUCH_SCROLL_CENTER) / 5;
    cocoa_touch_scroll_event(&s, 0, true, -travel, 0, record, frames);
    assert(count == 1 && frames[0].down);
    cocoa_touch_scroll_event(&s, 0, true, -1, 0, record, frames);
    assert(count == 3 && !frames[1].down && frames[2].down);
    assert(center(&frames[2]) == COCOA_TOUCH_SCROLL_MIN);
    assert(frames[2].y == COCOA_TOUCH_SCROLL_CENTER);
    cocoa_touch_scroll_event(&s, 0, true, 0, DBL_MAX, record, frames);
    assert(count == 5 && frames[4].y == COCOA_TOUCH_SCROLL_MAX);
    assert(center(&frames[4]) == COCOA_TOUCH_SCROLL_MIN);
    return 0;
}
''')
            compiler = shlex.split(os.environ.get("CC", "cc"))
            subprocess.run(compiler + ["-std=c11", "-Wall", "-Wextra", "-Werror",
                           str(work / "test.c"), "-lm", "-o", str(work / "test")],
                           check=True)
            subprocess.run([str(work / "test")], check=True)

    def test_routing_contract(self):
        cocoa = added_lines("ui/cocoa.m")
        self.assertIn("[event hasPreciseScrollingDeltas] &&", cocoa)
        self.assertIn("[event momentumPhase] == NSEventPhaseNone &&", cocoa)
        self.assertIn("[[self window] isKeyWindow] &&", cocoa)
        self.assertIn('getenv("TRYOMARCHY_TRACKPAD_SCROLL_SPEED")', cocoa)
        # Touch scrolling is tried first and falls back to the wheel path.
        self.assertIn("if ([self handleTouchScrollLocked:event]) {", cocoa)
        # Pinch and scroll share two slots; each gesture evicts the other.
        self.assertIn("[self endPinchLocked];", cocoa)
        self.assertEqual(cocoa.count("[self endTouchScrollLocked];"), 2)
        self.assertIn("[cocoaView endTouchScrollLocked];", cocoa)

    def test_touchpad_keeps_pinch_geometry_in_millimetres(self):
        device = added_lines("hw/input/virtio-input-hid.c")
        self.assertIn("BTN_TOOL_TRIPLETAP", device)
        self.assertIn("config.u.abs.res = const_le32(41);", device)
        pinch = added_lines("include/ui/cocoa-pinch.h")
        radius = int(re.search(r"COCOA_PINCH_RADIUS = (\d+),", pinch)[1])
        self.assertAlmostEqual(radius / 41, 4096 / 327, delta=0.05)

    def test_builder_verifies_and_applies_exact_patch_last(self):
        builder = (ROOT / "macos/build-qemu-gpu-runtime.sh").read_text()
        expected = re.search(r"^touch_scroll_patch_sha256=([a-f0-9]{64})$", builder, re.M)
        self.assertIsNotNone(expected)
        self.assertEqual(hashlib.sha256(PATCH.read_bytes()).hexdigest(), expected[1])
        applies = re.findall(r'^patch -d "\$source_dir" -p1 -f -i "\$(\w+)"$', builder, re.M)
        self.assertEqual(applies[-1], "touch_scroll_patch")
        self.assertLess(applies.index("pinch_patch"), applies.index("precise_scroll_patch"))


if __name__ == "__main__":
    unittest.main()
