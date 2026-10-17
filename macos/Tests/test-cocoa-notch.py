#!/usr/bin/env python3
"""Check, place and compile the Cocoa full screen beside the camera notch."""

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
PATCH = ROOT / "macos/patches/qemu-cocoa-notch.patch"
BUILDER = ROOT / "macos/build-qemu-gpu-runtime.sh"


def patched() -> str:
    """The patched side of every hunk: context and added lines."""
    lines = PATCH.read_text(encoding="utf-8").splitlines()
    body = lines[next(i for i, line in enumerate(lines) if line.startswith("@@")):]
    return "\n".join(line[1:] for line in body if line[:1] in (" ", "+"))


def added() -> str:
    return "\n".join(
        line[1:]
        for line in PATCH.read_text(encoding="utf-8").splitlines()
        if line.startswith("+") and not line.startswith("+++")
    )


def block(text: str, start: str) -> str:
    """A definition (not a declaration): start, its body, its closing brace."""
    begin = text.index(start + "\n{")
    return text[begin: text.index("\n}\n", begin) + 3]


class CocoaNotchTests(unittest.TestCase):
    def test_builder_pins_and_applies_the_patch_last(self) -> None:
        builder = BUILDER.read_text(encoding="utf-8")
        digest = hashlib.sha256(PATCH.read_bytes()).hexdigest()
        self.assertIn(f"notch_patch_sha256={digest}", builder)
        self.assertIn('verify_file_sha "Try Omarchy Cocoa notch patch"', builder)
        applied = re.findall(r'^patch -d "\$source_dir" -p1 -f -i "\$(\w+)"$', builder, re.MULTILINE)
        self.assertEqual(applied[-1], "notch_patch")

    def test_one_private_method_checked_before_use(self) -> None:
        install = block(patched(), "static void cocoa_notch_hook_install(void)")
        self.assertIn('NSClassFromString(@"_NSFullScreenContentController")', install)
        self.assertIn('NSSelectorFromString(@"reservesSpaceForMenuBarInFullScreen")', install)
        self.assertIn('strcmp(method_getTypeEncoding(method), "B16@0:8") != 0', install)
        # A missing or changed method turns the whole feature off.
        self.assertLess(install.index("notch_panel_enabled = false;"), install.index("method_setImplementation"))
        # No other private AppKit or SkyLight piece.
        text = added()
        self.assertEqual(re.findall(r'NSClassFromString\(@"(\w+)"\)', text), ["_NSFullScreenContentController"])
        for private in ("SLS", "CGS", "dlsym", "_NSFullScreenMenuBarCompanionController"):
            self.assertNotIn(private, text)

    def test_reservation_stays_off_screens_without_a_housing(self) -> None:
        hook = block(patched(), "static BOOL cocoa_notch_reserves_menu_bar(id self, SEL cmd)")
        self.assertIn("BOOL reserves = cocoa_reserves_menu_bar(self, cmd);", hook)
        self.assertIn("return reserves && cocoa_notch_strip(", hook)
        self.assertIn("!immersive_mode_enabled", hook)
        self.assertIn('@"AppleMenuBarVisibleInFullscreen"', hook)

    def test_level_rises_only_while_covering_the_strip_with_the_keyboard(self) -> None:
        level = block(patched(), "- (void) updateNotchLevel")
        self.assertIn("bool covered = [self coversNotch];", level)
        for condition in ("!notchLeaving", "[window isKeyWindow]", "[NSApp isActive]",
                          "notchReveal == COCOA_REVEAL_NONE", "!menuTracking"):
            self.assertIn(condition, level)
        self.assertIn("raised ? NSStatusWindowLevel : NSNormalWindowLevel", level)
        # Entering full screen, a resize or new screen, the keyboard and the
        # app's focus re-evaluate it.
        text = patched()
        self.assertEqual(added().count("    [cocoaView updateNotchLevel];"), 7)
        for delegate in ("windowDidBecomeKey", "applicationDidBecomeActive"):
            self.assertIn("[cocoaView updateNotchLevel];",
                          block(text, f"- (void){delegate}:(NSNotification *)notification"))
        self.assertIn("[cocoaView setNotchLeaving:true];",
                      block(text, "- (void)windowWillExitFullScreen:(NSNotification *)notification"))

    def test_guest_is_offered_the_whole_display_while_covering(self) -> None:
        text = patched()
        safe = block(text, "- (NSSize) screenSafeAreaSize")
        self.assertLess(safe.index("if ([self coversNotch])"), safe.index("insets.top + insets.bottom"))
        # resizeWindow, from its first line on.
        resize = text[text.index("    [[self window] setContentAspectRatio:"):]
        self.assertLess(resize.index("if ([self coversNotch])"), resize.index("NSWindowStyleMaskResizable"))

    def test_menu_bar_and_dock_reveal_only_outside_immersive_mode(self) -> None:
        reveal = block(patched(), "- (void) updateNotchReveal")
        self.assertIn("if (!immersive_mode_enabled && [self coversNotch])", reveal)
        self.assertIn("COCOA_REVEAL_MENU_BAR", reveal)
        self.assertIn("COCOA_REVEAL_DOCK", reveal)
        text = patched()
        for handler in ("- (void) mouseMoved:(NSEvent *)event\n{\n",
                        "- (void) mouseDragged:(NSEvent *)event\n{\n"):
            self.assertIn(handler + "    [self updateNotchReveal];", text)

    def test_opt_out_and_hook_come_before_full_screen(self) -> None:
        text = patched()
        self.assertIn("                             opts->u.cocoa.immersive;\n"
                      "    notch_panel_enabled = !getenv(\"TRYOMARCHY_NOTCH\") ||\n", text)
        after = text[text.index('getenv("TRYOMARCHY_NOTCH")'):]
        self.assertLess(after.index("cocoa_notch_hook_install();"),
                        after.index("/* if fullscreen mode is to be used */"))

    def test_hook_compiles_installs_and_measures_edges(self) -> None:
        text = patched()
        helpers = "\n".join(block(text, start) for start in (
            "static CGFloat cocoa_notch_strip(NSScreen *screen)",
            "static NSRectEdge cocoa_dock_edge(void)",
            "static CGFloat cocoa_dock_reach(void)",
            "static CGFloat cocoa_edge_distance(NSPoint point, NSRect frame, NSRectEdge edge)",
            "static BOOL cocoa_notch_reserves_menu_bar(id self, SEL cmd)",
            "static void cocoa_notch_hook_install(void)",
        ))
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            source = work / "notch.m"
            source.write_text(
                f"""
#import <AppKit/AppKit.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <string.h>

#define info_report(...) (printf(__VA_ARGS__), printf("\\n"))
static bool notch_panel_enabled = true;
static bool immersive_mode_enabled = true;
static NSView *cocoaView;
static BOOL (*cocoa_reserves_menu_bar)(id, SEL);

{helpers}

int main(void)
{{
    NSRect frame = NSMakeRect(0, 0, 1512, 982);
    printf("%g %g %g %g\\n",
           cocoa_edge_distance(NSMakePoint(10, 981), frame, NSRectEdgeMaxY),
           cocoa_edge_distance(NSMakePoint(10, 3), frame, NSRectEdgeMinY),
           cocoa_edge_distance(NSMakePoint(4, 500), frame, NSRectEdgeMinX),
           cocoa_edge_distance(NSMakePoint(1500, 500), frame, NSRectEdgeMaxX));
    CGFloat reach = cocoa_dock_reach();
    printf("%d\\n", reach >= 48 && reach <= 288);
    (void)cocoaView;
    cocoa_notch_hook_install();
    /* This macOS still has the method, with the signature the hook expects. */
    printf("%s\\n", cocoa_reserves_menu_bar ? "hooked" : "fallback");
    notch_panel_enabled = false;
    printf("%g\\n", cocoa_notch_strip([NSScreen mainScreen]));
    return 0;
}}
""",
                encoding="utf-8",
            )
            compiler = shlex.split(os.environ.get("CC", "cc"))
            binary = work / "notch"
            subprocess.run(
                compiler + ["-fno-objc-arc", "-mmacosx-version-min=15.0", "-Wall", "-Wextra", "-Werror",
                            "-Wno-unused-function", "-Wno-unused-parameter", str(source),
                            "-framework", "AppKit", "-o", str(binary)],
                check=True,
            )
            result = subprocess.run([str(binary)], capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.splitlines(), ["1 3 4 12", "1", "hooked", "0"])


if __name__ == "__main__":
    unittest.main()
