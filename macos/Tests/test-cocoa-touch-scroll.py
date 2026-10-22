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

enum { B = COCOA_TOUCH_SCROLL_BEGIN, E = COCOA_TOUCH_SCROLL_END,
       C = COCOA_TOUCH_SCROLL_CANCEL, M = COCOA_TOUCH_SCROLL_MOMENTUM,
       ME = COCOA_TOUCH_SCROLL_MOMENTUM_END };

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
        /* Never the pinch bridge's IDs, and within ABS_MT_TRACKING_ID. */
        assert(frame->id[0] >= 2 && frame->id[1] == frame->id[0] + 1);
        assert(frame->id[1] <= 65535);
    }
}

static int center(const CocoaTouchScrollFrame *frame)
{
    return (frame->x[0] + frame->x[1]) / 2;
}

static bool event(CocoaTouchScroll *s, unsigned phase, bool eligible,
                  double dx, double dy)
{
    return cocoa_touch_scroll_event(s, phase, eligible, dx, dy, record, frames);
}

int main(void)
{
    CocoaTouchScroll s = {0};

    /* A scroll that began elsewhere, or outside the view, stays on the wheel. */
    assert(!event(&s, 0, true, 1, 1));
    assert(!event(&s, B, false, 0, 0));
    assert(count == 0);
    /* So does its momentum. */
    assert(!event(&s, M, true, 0, 5));
    assert(!event(&s, M | ME, true, 0, 1));

    /* Begin places both contacts at the center; Cocoa's +y lifts the fingers. */
    assert(event(&s, B, true, 0, 0));
    assert(count == 1 && frames[0].down);
    assert(center(&frames[0]) == COCOA_TOUCH_SCROLL_CENTER);
    assert(frames[0].y == COCOA_TOUCH_SCROLL_CENTER);
    assert(event(&s, 0, true, 0, 10));
    assert(count == 2 && frames[1].down);
    assert(frames[1].y == COCOA_TOUCH_SCROLL_CENTER - lround(10 * COCOA_TOUCH_SCROLL_UNITS_PER_POINT));
    assert(frames[1].id[0] == frames[0].id[0]);
    assert(event(&s, 0, true, -4, 0));
    assert(center(&frames[2]) == COCOA_TOUCH_SCROLL_CENTER + lround(4 * COCOA_TOUCH_SCROLL_UNITS_PER_POINT));

    /* Fractional points accumulate in sensor units, not per event. */
    for (int i = 0; i < 10; i++) {
        event(&s, 0, true, 0, -0.1);
        count = 3;
    }
    assert(fabs(s.y - (COCOA_TOUCH_SCROLL_CENTER - 9 * COCOA_TOUCH_SCROLL_UNITS_PER_POINT)) < 1e-9);

    /* Zero deltas emit nothing; end releases once. */
    assert(event(&s, 0, true, 0, 0));
    assert(count == 3);
    assert(event(&s, E, true, 0, 0));
    assert(count == 4 && !frames[3].down);

    /* Its momentum is dropped: the guest scrolls kinetically by itself. */
    assert(event(&s, M, true, 0, 30));
    assert(event(&s, M, false, 0, 20));
    assert(event(&s, M | ME, true, 0, 1));
    assert(count == 4);
    assert(!event(&s, M, true, 0, 5));  /* a stray later momentum event */
    assert(!event(&s, 0, true, 0, 5));  /* an orphaned update */

    /* Deltas carried by the end event move before the release. */
    int previous = frames[0].id[0];
    event(&s, B, true, 0, 0);
    assert(frames[4].id[0] == previous + 2);  /* fresh IDs for every landing */
    event(&s, E, true, 2, 0);
    assert(count == 7 && frames[5].down && !frames[6].down);
    assert(center(&frames[5]) == COCOA_TOUCH_SCROLL_CENTER - lround(2 * COCOA_TOUCH_SCROLL_UNITS_PER_POINT));

    /* A new gesture outside the view does not inherit dropped momentum. */
    event(&s, B, false, 0, 0);
    assert(!event(&s, M, true, 0, 5));

    /* Cancel, focus loss, leaving the view and invalid deltas release. */
    count = 0;
    event(&s, B, true, 0, 0);
    assert(event(&s, C, true, 0, 0));
    assert(count == 2 && !frames[1].down);
    event(&s, B, true, 0, 0);
    cocoa_touch_scroll_cancel(&s, record, frames);
    assert(count == 4 && !frames[3].down);
    cocoa_touch_scroll_cancel(&s, record, frames);
    assert(count == 4);
    event(&s, B, true, 0, 0);
    assert(!event(&s, 0, false, 0, 3));
    assert(count == 6 && !frames[5].down);
    assert(!event(&s, 0, true, 0, 3));  /* the rest of that gesture: wheel */
    assert(event(&s, M, true, 0, 3));   /* but the guest saw fingers lift */
    event(&s, B, true, 0, 0);
    assert(!event(&s, 0, true, NAN, 0));
    assert(count == 8 && !frames[7].down);
    assert(!event(&s, B, true, 0, INFINITY));
    assert(count == 8 && !s.active);

    /* A new begin replaces stale contacts with a release first. */
    event(&s, B, true, 0, 0);
    event(&s, B, true, 0, 0);
    assert(count == 11 && frames[8].down && !frames[9].down && frames[10].down);
    assert(frames[10].id[0] != frames[8].id[0]);

    /* Reaching an edge lifts and lands again on the far side of that axis. */
    count = 0;
    int travel = (int)((COCOA_TOUCH_SCROLL_MAX - COCOA_TOUCH_SCROLL_CENTER) /
                       COCOA_TOUCH_SCROLL_UNITS_PER_POINT);
    event(&s, 0, true, -travel, 0);
    assert(count == 1 && frames[0].down);
    event(&s, 0, true, -1, 0);
    assert(count == 3 && !frames[1].down && frames[2].down);
    assert(frames[2].id[0] != frames[0].id[0]);
    assert(center(&frames[2]) == COCOA_TOUCH_SCROLL_MIN);
    assert(frames[2].y == COCOA_TOUCH_SCROLL_CENTER);
    event(&s, 0, true, 0, DBL_MAX);
    assert(count == 5 && frames[4].y == COCOA_TOUCH_SCROLL_MAX);
    assert(center(&frames[4]) == COCOA_TOUCH_SCROLL_MIN);

    /* Tracking IDs wrap inside the advertised range. */
    s.gesture = 32766;
    assert(cocoa_touch_scroll_id(&s, 1) == 65535);
    s.gesture = 32767;
    assert(cocoa_touch_scroll_id(&s, 0) == 2);
    return 0;
}
''')
            compiler = shlex.split(os.environ.get("CC", "cc"))
            subprocess.run(compiler + ["-std=c11", "-Wall", "-Wextra", "-Werror",
                           str(work / "test.c"), "-lm", "-o", str(work / "test")],
                           check=True)
            subprocess.run([str(work / "test")], check=True)

    def test_routing_contract(self):
        cocoa = added_file("ui/cocoa.m")
        self.assertIn("bool eligible = [event hasPreciseScrollingDeltas] &&", cocoa)
        self.assertIn("[[self window] isKeyWindow] &&", cocoa)
        self.assertIn("if (momentum != NSEventPhaseNone) {", cocoa)
        self.assertIn("if (momentum & (NSEventPhaseEnded | NSEventPhaseCancelled)) {", cocoa)
        # Touch scrolling is tried first and falls back to the wheel path.
        self.assertIn("if ([self handleTouchScrollLocked:event]) {", cocoa)
        # Pinch and scroll share two slots; an eligible begin evicts the other.
        self.assertIn("        if (eligible) {\n"
                      "            [self endPinchLocked];", cocoa)
        self.assertIn("        if (eligible) {\n"
                      "            [self endTouchScrollLocked];", cocoa)
        self.assertEqual(cocoa.count("[self endTouchScrollLocked];"), 2)
        self.assertIn("[cocoaView endTouchScrollLocked];", cocoa)
        # One frame sender serves both gestures.
        self.assertIn("static void cocoa_touchpad_send(bool down, const int x[2], int y,", cocoa)
        self.assertIn("cocoa_touchpad_send(frame->down, frame->x, COCOA_PINCH_CENTER, ids);", cocoa)

    def test_touchpad_device_belongs_to_the_pinch_patch(self):
        source = PATCH.read_text()
        self.assertNotIn("diff --git a/hw/input/virtio-input-hid.c", source)
        self.assertNotIn("diff --git a/include/ui/cocoa-pinch.h", source)
        self.assertNotIn("BTN_TOOL_TRIPLETAP", source)

    def test_builder_verifies_and_applies_exact_patch_after_cocoa_patches(self):
        builder = (ROOT / "macos/build-qemu-gpu-runtime.sh").read_text()
        expected = re.search(r"^touch_scroll_patch_sha256=([a-f0-9]{64})$", builder, re.M)
        self.assertIsNotNone(expected)
        self.assertEqual(hashlib.sha256(PATCH.read_bytes()).hexdigest(), expected[1])
        applies = re.findall(r'^patch -d "\$source_dir" -p1 -f -i "\$(\w+)"$', builder, re.M)
        self.assertLess(applies.index("command_chord_patch"), applies.index("touch_scroll_patch"))
        self.assertLess(applies.index("pinch_patch"), applies.index("precise_scroll_patch"))


if __name__ == "__main__":
    unittest.main()
