#!/usr/bin/env python3
"""Compile and exercise the Cocoa release-key parser and matcher, without AppKit."""

from __future__ import annotations

import hashlib
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "macos/patches/qemu-cocoa-release-key.patch"
SHORTCUTS_PATCH = ROOT / "macos/patches/qemu-cocoa-host-shortcuts.patch"
BUILDER = ROOT / "macos/build-qemu-gpu-runtime.sh"
LAUNCHER = ROOT / "macos/run-qemu-gpu.sh"


def plus_lines(patch: Path = PATCH) -> str:
    return "\n".join(
        line[1:]
        for line in patch.read_text(encoding="utf-8").splitlines()
        if line.startswith("+") and not line.startswith("+++")
    )


def patched_cocoa(patch: Path) -> str:
    """ui/cocoa.m as the patch leaves it, hunk by hunk."""
    section = patch.read_text(encoding="utf-8").split("+++ b/ui/cocoa.m\n", 1)[1]
    return "\n".join(
        line[1:] if line[:1] in " +" else line
        for line in section.splitlines()
        if not line.startswith("-")
    )


def extract(source: str, start: str, end: str) -> str:
    begin = source.index(start)
    finish = source.index(end, begin) + len(end)
    return source[begin:finish]


class CocoaReleaseKeyTests(unittest.TestCase):
    def test_parser_and_matcher(self) -> None:
        shortcuts = extract(
            patched_cocoa(SHORTCUTS_PATCH),
            "#define COCOA_HOST_SHORTCUT_MAX 64",
            "        cursor++;\n    }\n}",
        )
        cocoa = patched_cocoa(PATCH)
        state = extract(cocoa, "static CocoaHostShortcut cocoa_release_key;", "static bool keyboard_released;")
        functions = extract(
            cocoa,
            "/* Parse the release-key option",
            "    *pressed = cocoa_release_key_held;\n    return cocoa_release_key_held;\n}",
        )
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / "release-key.c").write_text(
                f"""
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>

typedef unsigned long NSEventModifierFlags;
enum {{
    NSEventModifierFlagCapsLock = 1 << 16,
    NSEventModifierFlagShift = 1 << 17,
    NSEventModifierFlagControl = 1 << 18,
    NSEventModifierFlagOption = 1 << 19,
    NSEventModifierFlagCommand = 1 << 20,
    NSEventModifierFlagFunction = 1 << 23,
}};
#define ARRAY_SIZE(x) (sizeof(x) / sizeof((x)[0]))

{shortcuts}

{state}

{functions}

static bool parse(const char *spec) {{
    return cocoa_parse_release_key(spec, &cocoa_release_key);
}}

int main(void) {{
    const NSEventModifierFlags ctrl_opt = NSEventModifierFlagControl | NSEventModifierFlagOption;
    bool pressed = true;

    /* One keycode with at least one modifier. */
    assert(parse("5+ctrl+opt"));
    assert(cocoa_release_key.keycode == 5 && cocoa_release_key.modifiers == ctrl_opt);
    assert(parse("48+cmd+shift"));
    assert(cocoa_release_key.modifiers == (NSEventModifierFlagCommand | NSEventModifierFlagShift));
    assert(!parse(""));
    assert(!parse("5"));
    assert(!parse("5+ctrl:6+ctrl"));
    assert(!parse("5+ctrl:"));
    assert(!parse("256+ctrl"));
    assert(!parse("5+fn"));
    assert(!parse("+ctrl"));

    /* Unset, nothing matches, and Control-Option-G keeps QEMU's meaning. */
    assert(!cocoa_release_key_event(5, ctrl_opt, true, false, &pressed) && !pressed);

    assert(parse("5+ctrl+opt"));
    cocoa_release_key_enabled = true;

    /* Exactly its modifiers press it; Caps Lock and Fn don't count. */
    assert(cocoa_release_key_event(5, ctrl_opt | NSEventModifierFlagCapsLock, true, false, &pressed) && pressed);
    assert(cocoa_release_key_event(5, ctrl_opt, false, false, &pressed) && !pressed);
    assert(!cocoa_release_key_event(5, NSEventModifierFlagControl, true, false, &pressed) && !pressed);
    assert(!cocoa_release_key_event(5, ctrl_opt | NSEventModifierFlagShift, true, false, &pressed));
    assert(!cocoa_release_key_event(6, ctrl_opt, true, false, &pressed));
    assert(!cocoa_release_key_event(5, 0, false, false, &pressed));

    /* Its repeats and key up follow the press, after the modifiers are let go. */
    assert(cocoa_release_key_event(5, ctrl_opt, true, false, &pressed) && pressed);
    assert(cocoa_release_key_event(5, 0, true, true, &pressed) && !pressed);
    assert(cocoa_release_key_event(5, 0, false, false, &pressed) && !pressed);
    assert(!cocoa_release_key_event(5, 0, false, false, &pressed));

    /* A G the guest holds stays with the guest when the modifiers join. */
    assert(!cocoa_release_key_event(5, 0, true, false, &pressed));
    assert(!cocoa_release_key_event(5, ctrl_opt, true, true, &pressed) && !pressed);
    assert(!cocoa_release_key_event(5, ctrl_opt, false, false, &pressed));
    return 0;
}}
""",
                encoding="utf-8",
            )
            subprocess.run(
                ["cc", "-std=c11", "-Wall", "-Werror", "-Wno-unused-variable", "-o", str(work / "release-key"),
                 str(work / "release-key.c")],
                check=True,
            )
            subprocess.run([str(work / "release-key")], check=True)

    def test_released_keyboard_is_not_captured_until_the_vm_is_focused_again(self) -> None:
        cocoa = patched_cocoa(PATCH)
        self.assertIn("(isMouseGrabbed || full_grab_enabled) && !keyboard_released;", cocoa)
        released = extract(cocoa, "- (void) setKeyboardReleased:(bool)released\n{", "\n    }\n}\n")
        self.assertIn("[heads[i].view ungrabMouse];", released)
        self.assertIn("[self raiseAllKeys];", released)
        self.assertIn("- (void)applicationDidBecomeActive:(NSNotification *)notification\n{\n"
                      "    keyboard_released = false;", cocoa)
        for handler in ("mouseDown", "rightMouseDown", "otherMouseDown"):
            self.assertIn(f"- (void) {handler}:(NSEvent *)event\n{{\n    keyboard_released = false;", cocoa)
        self.assertLess(released.index("ungrabMouse"), released.index("qemu_input_event_sync();"))

    def test_the_tap_catches_the_release_key_before_macos_while_released(self) -> None:
        cocoa = patched_cocoa(PATCH)
        tap = extract(cocoa, "    if (keyboard_released && [NSApp isActive] && cocoa_head_window_is_key() &&",
                      "            return NULL;\n        }\n    }")
        self.assertIn("cocoa_release_key_event(", tap)
        self.assertIn("[view setKeyboardReleased:false];", tap)
        self.assertLess(cocoa.index(tap), cocoa.index("    NSEvent *event = [NSEvent eventWithCGEvent:cgEvent];"))

    def test_a_key_the_guest_holds_goes_up_when_command_joins_it(self) -> None:
        self.assertIn("([event modifierFlags] & NSEventModifierFlagCommand) &&\n"
                      "                !qkbd_state_key_get(kbd, keycode)) {", patched_cocoa(PATCH))

    def test_the_key_handler_toggles_before_command_chords(self) -> None:
        cocoa = patched_cocoa(PATCH)
        key_down = extract(cocoa, "        case NSEventTypeKeyDown: {", "        case NSEventTypeKeyUp: {")
        toggle = key_down.index("[self setKeyboardReleased:!keyboard_released];")
        self.assertLess(toggle, key_down.index("// Keep Command chords with the host"))
        self.assertIn("if (cocoa_release_key_enabled) {\n                                break;", key_down)
        key_up = extract(cocoa, "        case NSEventTypeKeyUp: {", "        case NSEventTypeMagnify:")
        self.assertLess(key_up.index("cocoa_release_key_event("), key_up.index("cocoa_is_host_key("))

    def test_the_option_is_documented(self) -> None:
        added = plus_lines()
        self.assertIn("'*release-key': 'str'", added)
        self.assertIn("[,release-key=code+mod...]", added)

    def test_the_launcher_detects_the_error_message_qemu_prints(self) -> None:
        message = re.search(r'"cocoa: (release-key must be one keycode)', plus_lines())
        self.assertIsNotNone(message)
        self.assertIn(f"grep -aFq '{message.group(1)}'", LAUNCHER.read_text(encoding="utf-8"))

    def test_runtime_verifies_and_applies_it_last(self) -> None:
        builder = BUILDER.read_text(encoding="utf-8")
        expected = re.search(r"^release_key_patch_sha256=([a-f0-9]{64})$", builder, re.M)
        self.assertIsNotNone(expected)
        self.assertEqual(hashlib.sha256(PATCH.read_bytes()).hexdigest(), expected.group(1))
        self.assertIn('verify_file_sha "Try Omarchy Cocoa release-key patch"', builder)
        applied = re.findall(r'^patch -d "\$source_dir" -p1 -f -i "\$(\w+)"$', builder, re.M)
        self.assertEqual(applied[-1], "release_key_patch")


if __name__ == "__main__":
    unittest.main()
