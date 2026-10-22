#!/usr/bin/env python3
"""Checksum, place and compile the Cocoa multi-display heads, without QEMU."""

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
PATCH = ROOT / "macos/patches/qemu-cocoa-multi-display.patch"
BUILDER = ROOT / "macos/build-qemu-gpu-runtime.sh"
LAUNCHER = ROOT / "macos/run-qemu-gpu.sh"
HOST_CONFIG = ROOT / "guest/package/try-omarchy/files/usr/lib/try-omarchy/host-config"


def patch_lines(prefix: str) -> list[str]:
    return [
        line[1:]
        for line in PATCH.read_text(encoding="utf-8").splitlines()
        if line.startswith(prefix) and not line.startswith(prefix * 3)
    ]


class CocoaMultiDisplayTests(unittest.TestCase):
    def test_heads_replace_the_single_listener_surface_and_scanout(self) -> None:
        removed = patch_lines("-")
        for single in (
            "static DisplayChangeListener dcl;",
            "static DisplaySurface *surface;",
            "static bool gl_dirty;",
            "static uint32_t gl_scanout_id;",
            "static DisplayGLTextureBorrower gl_scanout_borrow;",
        ):
            self.assertIn(single, removed)
        added = "\n".join(patch_lines("+"))
        self.assertIn("typedef struct QemuCocoaHead {", added)
        self.assertIn("#define cocoa_head_of(listener) container_of(listener, QemuCocoaHead, dcl)", added)
        # The keyboard stays one, kept by the first head's view.
        self.assertNotIn("QKbdState *kbd;", added)
        self.assertIn("case NSEventTypeMagnify:\n    case NSEventTypeScrollWheel:\n"
                      "        view = cocoa_view_of_window([event window]);", added)
        # The other heads join once the desktop draws, so first-boot setup on
        # the kernel console keeps the built-in panel's size.
        self.assertIn("if (head->index > 0 && !secondary_heads_enabled) {", added)
        self.assertIn(".dpy_gl_context_created = cocoa_gl_context_created,", added)
        self.assertIn("qemu_console_gl_context_created(g->parent_obj.scanout[0].con, name);", added)
        self.assertIn("qemu_register_reset(cocoa_guest_reset, NULL);", added)
        # Full screen at launch is asked for once the app runs, and asked again
        # when AppKit dropped the request; the chain to the next head uses the
        # same path.
        self.assertIn("- (void)windowDidFailToEnterFullScreen:(NSWindow *)window", added)
        self.assertIn("    cocoa_enter_full_screen(0);\n", added)
        self.assertIn("            heads[next].full_screen_wanted = true;\n            cocoa_enter_full_screen(next);", added)
        self.assertNotIn("[heads[0].window toggleFullScreen: nil];", added)
        # The level guard lifts before the window entered full screen is
        # raised over the camera strip, or the bar beside the notch stays hidden.
        result = "\n".join(
            line[1:]
            for line in PATCH.read_text(encoding="utf-8").splitlines()
            if line[:1] in ("+", " ") and not line.startswith("+++")
        )
        entered = result[result.index("- (void)windowDidEnterFullScreen:"):]
        entered = entered[: entered.index("\n}\n")]
        self.assertLess(entered.index("full_screen_entering = false;"), entered.index("updateNotchLevel"))
        # The bar beside the notch stays while any window of the VM has the
        # keyboard, not only the panel's own.
        self.assertIn("cocoa_head_window_is_key() && [NSApp isActive] &&", added)

    def test_layout_and_gpu_id_are_the_launchers(self) -> None:
        added = "\n".join(patch_lines("+"))
        launcher = LAUNCHER.read_text(encoding="utf-8")
        self.assertIn('getenv("TRYOMARCHY_DISPLAY_LAYOUT")', added)
        self.assertIn("export TRYOMARCHY_DISPLAY_LAYOUT=$display_layout", launcher)
        self.assertIn('qemu_console_lookup_by_device_name("omarchy-gpu", i, NULL)', added)
        self.assertIn("virtio-gpu-gl-pci,id=omarchy-gpu,max_outputs=$display_count,xres=$gpu_xres,yres=$gpu_yres,", launcher)
        # Head N-1 shows Virtual-N: the same names the guest's host-config reads.
        self.assertIn('sscanf(entries[i], "Virtual-%u:%dx%d%n", &output, &x, &y, &end)', added)
        self.assertIn("placement='Virtual-[1-9][0-9]?:[0-9]{1,5}x[0-9]{1,5}'",
                      HOST_CONFIG.read_text(encoding="utf-8"))

    def test_desktop_is_the_union_of_every_heads_output(self) -> None:
        added = "\n".join(patch_lines("+"))
        function = added[added.index("static NSRect cocoa_desktop_rect(void)"):]
        function = function[: function.index("\n}\n") + 3]
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            source = work / "desktop.m"
            source.write_text(
                f"""
#import <Foundation/Foundation.h>
#include <assert.h>

typedef struct {{
    int desktop_x;
    int desktop_y;
    NSSize logicalSize;
}} QemuCocoaHead;
static QemuCocoaHead heads[4];
static unsigned head_count;

{function}

int main(void)
{{
    /* A MacBook panel with a 27-inch display to its right, bottoms aligned. */
    heads[0] = (QemuCocoaHead){{ 0, 458, NSMakeSize(1512, 982) }};
    heads[1] = (QemuCocoaHead){{ 1512, 0, NSMakeSize(2560, 1440) }};
    head_count = 2;
    assert(NSEqualRects(cocoa_desktop_rect(), NSMakeRect(0, 0, 4072, 1440)));

    /* A head the guest has not sized yet takes no room. */
    heads[1].logicalSize = NSZeroSize;
    assert(NSEqualRects(cocoa_desktop_rect(), NSMakeRect(0, 458, 1512, 982)));

    head_count = 1;
    heads[0] = (QemuCocoaHead){{ 0, 0, NSMakeSize(1920, 1080) }};
    assert(NSEqualRects(cocoa_desktop_rect(), NSMakeRect(0, 0, 1920, 1080)));
    return 0;
}}
""",
                encoding="utf-8",
            )
            compiler = shlex.split(os.environ.get("CC", "cc"))
            binary = work / "desktop"
            subprocess.run(
                compiler + ["-fno-objc-arc", "-Wall", "-Wextra", "-Werror", str(source),
                            "-framework", "Foundation", "-o", str(binary)],
                check=True,
            )
            subprocess.run([str(binary)], check=True)

    def test_builder_verifies_exact_patch_after_every_cocoa_patch(self) -> None:
        builder = BUILDER.read_text(encoding="utf-8")
        expected = re.search(r"^multi_display_patch_sha256=([a-f0-9]{64})$", builder, re.M)
        self.assertIsNotNone(expected)
        self.assertEqual(hashlib.sha256(PATCH.read_bytes()).hexdigest(), expected.group(1))
        apply = 'patch -d "$source_dir" -p1 -f -i "$multi_display_patch"'
        self.assertIn(apply, builder)
        # Last: its context is every other Cocoa patch's ui/cocoa.m.
        cocoa = re.findall(r'^patch -d "\$source_dir" -p1 -f -i "\$([a-z_]+)"$', builder, re.M)
        self.assertEqual(cocoa[-1], "multi_display_patch")
        self.assertGreater(cocoa.index("multi_display_patch"), cocoa.index("command_chord_patch"))


if __name__ == "__main__":
    unittest.main()
