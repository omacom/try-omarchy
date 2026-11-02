#!/usr/bin/env python3
"""Check the Cocoa immersive-mode and return-to-macOS shortcut patch."""

from __future__ import annotations

import hashlib
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "macos/patches/qemu-cocoa-immersive-hotkeys.patch"
BUILDER = ROOT / "macos/build-qemu-gpu-runtime.sh"


def body() -> list[str]:
    """The diff lines, from the first hunk on (the message above has bullets)."""
    text = PATCH.read_text(encoding="utf-8").splitlines()
    return text[next(i for i, line in enumerate(text) if line.startswith("@@")):]


def added() -> str:
    return "\n".join(line[1:] for line in body() if line.startswith("+"))


def hunks() -> list[str]:
    """The patched side of each hunk on its own: context and added lines."""
    result: list[list[str]] = []
    for line in body():
        if line.startswith("@@"):
            result.append([])
        elif line[:1] in (" ", "+"):
            result[-1].append(line[1:])
    return ["\n".join(hunk) + "\n" for hunk in result]


def block(signature: str) -> str:
    """A method or function from its signature to its closing brace, found in
    whichever hunk shows it. A hunk can end before the brace; then the rest
    of the hunk is what the patch shows of it."""
    for hunk in hunks():
        if signature in hunk:
            start = hunk.index(signature)
            end = hunk.find("\n}\n", start)
            return hunk[start:end if end >= 0 else len(hunk)]
    raise AssertionError(f"no hunk shows {signature!r}")


def hunk_with(needle: str) -> str:
    return next(hunk for hunk in hunks() if needle in hunk)


class CocoaImmersiveHotkeysTests(unittest.TestCase):
    def test_patch_has_no_removed_lines(self) -> None:
        removed = [line for line in body() if line.startswith("-") and not line.startswith("---")]
        self.assertEqual(removed, [])

    def test_builder_pins_and_applies_the_patch_last(self) -> None:
        builder = BUILDER.read_text(encoding="utf-8")
        digest = hashlib.sha256(PATCH.read_bytes()).hexdigest()
        self.assertIn(f"immersive_hotkeys_patch_sha256={digest}", builder)
        self.assertIn('verify_file_sha "Try Omarchy Cocoa immersive-hotkeys patch"', builder)
        self.assertIn('die "missing Cocoa immersive-hotkeys patch: $immersive_hotkeys_patch"', builder)
        applied = re.findall(r'^patch -d "\$source_dir" -p1 -f -i "\$(\w+)"$', builder, re.MULTILINE)
        self.assertEqual(applied[-1], "immersive_hotkeys_patch")

    def test_shortcuts_live_in_the_control_option_table(self) -> None:
        source = hunk_with("// handle control + alt Key Combos")
        table = source.index("// handle control + alt Key Combos")
        escape = source.index("[event keyCode] == kVK_Escape", table)
        upstream = source.index("switch (key)", table)
        self.assertLess(escape, upstream)
        self.assertNotIn("kVK_ANSI_F", added())

    def test_shift_picks_hiding_over_switching(self) -> None:
        source = hunk_with("// handle control + alt Key Combos")
        table = source[source.index("[event keyCode] == kVK_Escape"):source.index("switch (key)")]
        self.assertIn("bool to_host = [event modifierFlags] & NSEventModifierFlagShift;", table)
        self.assertLess(table.index("if (to_host) {"), table.index("cocoa_return_to_host();"))
        self.assertLess(table.index("cocoa_return_to_host();"), table.index("} else {"))
        self.assertLess(table.index("} else {"), table.index("cocoa_toggle_immersive();"))

    def test_shortcuts_act_outside_the_bql_and_ignore_repeats(self) -> None:
        source = hunk_with("// handle control + alt Key Combos")
        table = source[source.index("// handle control + alt Key Combos"):source.index("switch (key)")]
        self.assertEqual(table.count("![event isARepeat]"), 1)
        self.assertEqual(table.count("dispatch_async(dispatch_get_main_queue()"), 1)
        self.assertIn("cocoa_return_to_host();", table)
        self.assertIn("cocoa_toggle_immersive();", table)

    def test_toggle_follows_the_window_state(self) -> None:
        toggle = block("static void cocoa_toggle_immersive(void)\n{")
        self.assertIn("if (fullscreen_transitioning) {", toggle)
        self.assertIn("cocoa_set_immersive(!([window styleMask] & NSWindowStyleMaskFullScreen));", toggle)
        self.assertIn("[window toggleFullScreen:nil];", toggle)
        self.assertLess(toggle.index("cocoa_set_immersive("), toggle.index("toggleFullScreen"))

    def test_nothing_reenters_full_screen(self) -> None:
        self.assertNotIn("immersive_reenter_pending", added())
        self.assertEqual(added().count("toggleFullScreen"), 1)

    def test_every_transition_end_clears_the_transition_state(self) -> None:
        for source in (block("- (void)windowDidEnterFullScreen:"),
                       hunk_with("[cocoaView ungrabMouse];")):
            self.assertIn("fullscreen_transitioning = false;", source)
            self.assertIn("immersive_switch_pending = false;", source)
        for signature in ("- (void)windowWillEnterFullScreen:",
                          "- (void)windowWillExitFullScreen:"):
            self.assertIn("fullscreen_transitioning = true;", block(signature), signature)

    def test_a_failed_switch_restores_the_immersive_state(self) -> None:
        for signature in ("- (void)windowDidFailToEnterFullScreen:",
                          "- (void)windowDidFailToExitFullScreen:"):
            self.assertIn("cocoa_fullscreen_transition_failed();", block(signature), signature)
        failed = block("static void cocoa_fullscreen_transition_failed(void)\n{")
        self.assertIn("fullscreen_transitioning = false;", failed)
        self.assertIn("if (immersive_switch_pending) {", failed)
        self.assertIn("cocoa_set_immersive(immersive_before_switch);", failed)

    def test_return_to_host_hides_the_app_outside_transitions(self) -> None:
        host = block("static void cocoa_return_to_host(void)\n{")
        self.assertIn("if (fullscreen_transitioning) {", host)
        self.assertIn("[NSApp hide:nil];", host)

    def test_menu_item_reflects_the_launch_setting(self) -> None:
        text = added()
        self.assertIn('initWithTitle:@"Immersive Full Screen" action:@selector(toggleImmersive:)', text)
        self.assertIn('keyEquivalent:[NSString stringWithFormat:@"%C", (unichar)0x1b]', text)
        self.assertIn("NSEventModifierFlagControl | NSEventModifierFlagOption", text)
        init = hunk_with("immersive_mode_enabled = !opts->u.cocoa.has_immersive ||")
        launch = init.index("immersive_mode_enabled = !opts->u.cocoa.has_immersive ||")
        self.assertIn("[immersiveMenuItem setState:immersive_mode_enabled", init[launch:launch + 300])


if __name__ == "__main__":
    unittest.main()
