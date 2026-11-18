#!/usr/bin/env python3
"""Compile and exercise the Cocoa host-shortcuts parser and matcher, without AppKit."""

from __future__ import annotations

import hashlib
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "macos/patches/qemu-cocoa-host-shortcuts.patch"
COMMAND_PATCH = ROOT / "macos/patches/qemu-cocoa-command-chord-hold.patch"
BUILDER = ROOT / "macos/build-qemu-gpu-runtime.sh"
LAUNCHER = ROOT / "macos/run-qemu-gpu.sh"


def plus_lines(patch: Path = PATCH) -> str:
    return "\n".join(
        line[1:]
        for line in patch.read_text(encoding="utf-8").splitlines()
        if line.startswith("+") and not line.startswith("+++")
    )


def patched_cocoa() -> str:
    """ui/cocoa.m as the patch leaves it, hunk by hunk."""
    section = PATCH.read_text(encoding="utf-8").split("+++ b/ui/cocoa.m\n", 1)[1]
    return "\n".join(
        line[1:] if line[:1] in " +" else line
        for line in section.splitlines()
        if not line.startswith("-")
    )


def extract_c_block(source: str, start: str, end: str) -> str:
    begin = source.index(start)
    finish = source.index(end, begin) + len(end)
    return source[begin:finish]


class CocoaHostShortcutsTests(unittest.TestCase):
    def test_parser_and_matcher(self) -> None:
        code = extract_c_block(
            patched_cocoa(),
            "#define COCOA_HOST_SHORTCUT_MAX 64",
            "            cocoa_host_shortcut_held[keycode] = true;\n"
            "            return true;\n        }\n    }\n    return false;\n}",
        )
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / "host-shortcuts.c").write_text(
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
    NSEventModifierFlagNumericPad = 1 << 21,
    NSEventModifierFlagFunction = 1 << 23,
}};
#define ARRAY_SIZE(x) (sizeof(x) / sizeof((x)[0]))

{code}

static int count(const bool table[256]) {{
    int total = 0;
    for (int i = 0; i < 256; i++) total += table[i];
    return total;
}}

static bool parse(const char *spec) {{
    static bool table[256];
    return cocoa_parse_host_keys(spec, table, cocoa_host_shortcuts, &cocoa_host_shortcut_count);
}}

int main(void) {{
    bool table[256];
    CocoaHostShortcut shortcuts[COCOA_HOST_SHORTCUT_MAX];
    unsigned shortcut_count = 99;
    const NSEventModifierFlags ctrl = NSEventModifierFlagControl;
    const NSEventModifierFlags arrow = NSEventModifierFlagNumericPad | NSEventModifierFlagFunction;

    /* Bare keycodes keep their meaning. */
    assert(cocoa_parse_host_keys("", table, shortcuts, &shortcut_count));
    assert(count(table) == 0 && shortcut_count == 0);
    assert(cocoa_parse_host_keys("131:144:145:160", table, shortcuts, &shortcut_count));
    assert(table[131] && table[144] && table[145] && table[160] && count(table) == 4);
    assert(shortcut_count == 0);

    /* Keycodes with modifiers are shortcuts, not dedicated keys. */
    assert(cocoa_parse_host_keys("160:123+ctrl:124+ctrl:18+opt+shift+cmd", table, shortcuts, &shortcut_count));
    assert(table[160] && count(table) == 1 && shortcut_count == 3);
    assert(shortcuts[0].keycode == 123 && shortcuts[0].modifiers == ctrl);
    assert(shortcuts[2].keycode == 18);
    assert(shortcuts[2].modifiers == (NSEventModifierFlagOption | NSEventModifierFlagShift | NSEventModifierFlagCommand));
    assert(cocoa_parse_host_keys("0+cmd:255+ctrl+ctrl", table, shortcuts, &shortcut_count));
    assert(shortcut_count == 2 && shortcuts[1].modifiers == ctrl);

    assert(!cocoa_parse_host_keys("256+ctrl", table, shortcuts, &shortcut_count));
    assert(!cocoa_parse_host_keys("123+", table, shortcuts, &shortcut_count));
    assert(!cocoa_parse_host_keys("123+control", table, shortcuts, &shortcut_count));
    assert(!cocoa_parse_host_keys("123+ctr", table, shortcuts, &shortcut_count));
    assert(!cocoa_parse_host_keys("123+fn", table, shortcuts, &shortcut_count));
    assert(!cocoa_parse_host_keys("+ctrl", table, shortcuts, &shortcut_count));
    assert(!cocoa_parse_host_keys("123ctrl", table, shortcuts, &shortcut_count));
    assert(!cocoa_parse_host_keys("123+ctrl,124+ctrl", table, shortcuts, &shortcut_count));
    assert(!cocoa_parse_host_keys("123+ctrl:", table, shortcuts, &shortcut_count));
    assert(!cocoa_parse_host_keys("144,145", table, shortcuts, &shortcut_count));

    char many[1024] = "";
    for (int i = 0; i < COCOA_HOST_SHORTCUT_MAX; i++) {{
        strcat(many, i ? ":1+ctrl" : "1+ctrl");
    }}
    assert(cocoa_parse_host_keys(many, table, shortcuts, &shortcut_count));
    assert(shortcut_count == COCOA_HOST_SHORTCUT_MAX);
    strcat(many, ":1+ctrl");
    assert(!cocoa_parse_host_keys(many, table, shortcuts, &shortcut_count));

    assert(parse("123+ctrl:124+ctrl"));

    /* Exactly the shortcut's modifiers match; Caps Lock, Fn and the keypad flag don't count. */
    assert(cocoa_host_shortcut_event(124, ctrl | arrow, true, false));
    assert(cocoa_host_shortcut_event(124, ctrl | arrow, false, false));
    assert(cocoa_host_shortcut_event(124, ctrl | NSEventModifierFlagCapsLock, true, false));
    assert(cocoa_host_shortcut_event(124, ctrl, false, false));
    assert(!cocoa_host_shortcut_event(124, arrow, true, false));
    assert(!cocoa_host_shortcut_event(124, arrow, false, false));
    assert(!cocoa_host_shortcut_event(124, ctrl | NSEventModifierFlagShift | arrow, true, false));
    assert(!cocoa_host_shortcut_event(124, ctrl | NSEventModifierFlagShift | arrow, false, false));
    assert(!cocoa_host_shortcut_event(125, ctrl | arrow, true, false));
    assert(!cocoa_host_shortcut_event(300, ctrl, true, false));

    /* Repeats and the key up follow the key down after Control is let go. */
    assert(cocoa_host_shortcut_event(123, ctrl | arrow, true, false));
    assert(cocoa_host_shortcut_event(123, arrow, true, true));
    assert(cocoa_host_shortcut_event(123, arrow, false, false));
    assert(!cocoa_host_shortcut_event(123, arrow, false, false));

    /* An arrow the guest holds stays with the guest when Control joins. */
    assert(!cocoa_host_shortcut_event(123, arrow, true, false));
    assert(!cocoa_host_shortcut_event(123, ctrl | arrow, true, true));
    assert(!cocoa_host_shortcut_event(123, ctrl | arrow, false, false));

    /* The tap and the key window can both see one press. */
    assert(cocoa_host_shortcut_event(123, ctrl | arrow, true, false));
    assert(cocoa_host_shortcut_event(123, ctrl | arrow, true, false));
    assert(cocoa_host_shortcut_event(123, ctrl | arrow, false, false));
    assert(!cocoa_host_shortcut_event(123, ctrl | arrow, false, false));

    /* A missed key up can't hand the next plain press to macOS. */
    assert(cocoa_host_shortcut_event(124, ctrl | arrow, true, false));
    assert(!cocoa_host_shortcut_event(124, arrow, true, false));
    return 0;
}}
""",
                encoding="utf-8",
            )
            subprocess.run(
                ["cc", "-std=c11", "-Wall", "-Werror", "-Wno-unused-variable", "-o", str(work / "host-shortcuts"),
                 str(work / "host-shortcuts.c")],
                check=True,
            )
            subprocess.run([str(work / "host-shortcuts")], check=True)

    def test_the_tap_remembers_command_from_its_own_events(self) -> None:
        command_down = extract_c_block(
            plus_lines(COMMAND_PATCH),
            "#define COCOA_DEVICE_LEFT_COMMAND",
            "    return modifiers & NSEventModifierFlagCommand;\n}",
        )
        tap_flags = extract_c_block(
            patched_cocoa(),
            "static NSEventModifierFlags cocoa_host_shortcut_tap_flags(",
            "        flags |= NSEventModifierFlagCommand;\n    }\n    return flags;\n}",
        )
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / "tap-flags.c").write_text(
                f"""
#include <assert.h>
#include <stdbool.h>

typedef unsigned long NSUInteger;
typedef unsigned long NSEventModifierFlags;
typedef unsigned long long CGEventFlags;
typedef enum {{ kCGEventKeyDown = 10, kCGEventKeyUp = 11, kCGEventFlagsChanged = 12 }} CGEventType;
typedef enum {{ kCGKeyboardEventKeycode = 9 }} CGEventField;
typedef struct {{ long keycode; CGEventFlags flags; }} Event, *CGEventRef;
enum {{ NSEventModifierFlagControl = 1 << 18, NSEventModifierFlagCommand = 1 << 20 }};
enum {{ kVK_Command = 0x37, kVK_RightCommand = 0x36 }};
static CGEventFlags CGEventGetFlags(CGEventRef event) {{ return event->flags; }}
static long CGEventGetIntegerValueField(CGEventRef event, CGEventField field) {{ return event->keycode; }}
static bool cocoa_host_shortcut_left_command;
static bool cocoa_host_shortcut_right_command;

{command_down}

{tap_flags}

int main(void) {{
    const NSEventModifierFlags cmd = NSEventModifierFlagCommand;
    Event left_down = {{ kVK_Command, cmd | COCOA_DEVICE_LEFT_COMMAND }};
    Event right_down = {{ kVK_RightCommand, cmd | COCOA_DEVICE_LEFT_COMMAND | COCOA_DEVICE_RIGHT_COMMAND }};
    Event left_up = {{ kVK_Command, cmd | COCOA_DEVICE_RIGHT_COMMAND }};
    Event right_up = {{ kVK_RightCommand, 0 }};
    Event space = {{ 49, 0 }};
    Event control_space = {{ 49, NSEventModifierFlagControl }};

    assert(cocoa_host_shortcut_tap_flags(kCGEventKeyDown, &space) == 0);

    /* A key pressed with Command reaches the tap without the flag. */
    assert(cocoa_host_shortcut_tap_flags(kCGEventFlagsChanged, &left_down) & cmd);
    assert(cocoa_host_shortcut_tap_flags(kCGEventKeyDown, &space) == cmd);
    assert(cocoa_host_shortcut_tap_flags(kCGEventKeyUp, &control_space) == (cmd | NSEventModifierFlagControl));

    /* Command stays until both Command keys are up. */
    cocoa_host_shortcut_tap_flags(kCGEventFlagsChanged, &right_down);
    cocoa_host_shortcut_tap_flags(kCGEventFlagsChanged, &left_up);
    assert(cocoa_host_shortcut_tap_flags(kCGEventKeyDown, &space) == cmd);
    cocoa_host_shortcut_tap_flags(kCGEventFlagsChanged, &right_up);
    assert(cocoa_host_shortcut_tap_flags(kCGEventKeyDown, &space) == 0);
    assert(cocoa_host_shortcut_tap_flags(kCGEventKeyDown, &control_space) == NSEventModifierFlagControl);
    return 0;
}}
""",
                encoding="utf-8",
            )
            subprocess.run(
                ["cc", "-std=c11", "-Wall", "-Werror", "-Wno-unused-parameter", "-o", str(work / "tap-flags"),
                 str(work / "tap-flags.c")],
                check=True,
            )
            subprocess.run([str(work / "tap-flags")], check=True)

    def test_tap_and_window_paths_both_leave_shortcuts_alone(self) -> None:
        added = plus_lines()
        self.assertIn("[,host-keys=code[+mod...]:...]", added)
        patch = PATCH.read_text(encoding="utf-8")
        tap_guard = patch.index("cocoa_host_shortcut_event(\n+            CGEventGetIntegerValueField(cgEvent, kCGKeyboardEventKeycode),")
        conversion = patch.index("     NSEvent *event = [NSEvent eventWithCGEvent:cgEvent];")
        self.assertLess(tap_guard, conversion)
        flags = patch.index("+    NSEventModifierFlags shortcut_flags =\n+        cocoa_host_shortcut_tap_flags(type, cgEvent);")
        self.assertLess(flags, tap_guard)
        self.assertIn("            shortcut_flags,\n            type == kCGEventKeyDown,", added)
        self.assertIn("kCGKeyboardEventAutorepeat", added)
        self.assertIn("if (cocoa_host_shortcut_event([event keyCode], [event modifierFlags],\n"
                      "                                          true, [event isARepeat])) {", added)
        self.assertIn("if (cocoa_host_shortcut_event([event keyCode], [event modifierFlags],\n"
                      "                                          false, false)) {", added)

    def test_the_launcher_detects_the_error_message_qemu_prints(self) -> None:
        added = plus_lines()
        message = re.search(r'"(optional \+ctrl, \+opt, \+shift or \+cmd)', added)
        self.assertIsNotNone(message)
        self.assertIn(f"grep -aFq '{message.group(1)}'", LAUNCHER.read_text(encoding="utf-8"))

    def test_runtime_verifies_and_applies_it_last(self) -> None:
        builder = BUILDER.read_text(encoding="utf-8")
        expected = re.search(r"^host_shortcuts_patch_sha256=([a-f0-9]{64})$", builder, re.M)
        self.assertIsNotNone(expected)
        self.assertEqual(hashlib.sha256(PATCH.read_bytes()).hexdigest(), expected.group(1))
        self.assertIn('verify_file_sha "Try Omarchy Cocoa host-shortcuts patch"', builder)
        applied = re.findall(r'^patch -d "\$source_dir" -p1 -f -i "\$(\w+)"$', builder, re.M)
        self.assertEqual(applied[-1], "host_shortcuts_patch")
        self.assertLess(applied.index("host_keys_patch"), applied.index("host_shortcuts_patch"))


if __name__ == "__main__":
    unittest.main()
