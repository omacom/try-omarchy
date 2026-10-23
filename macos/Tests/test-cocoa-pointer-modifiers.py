#!/usr/bin/env python3
"""Compile the Cocoa modifier sync without AppKit and replay pointer and keyboard events."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "macos/patches/qemu-cocoa-pointer-keeps-modifiers.patch"
BUILDER = ROOT / "macos/build-qemu-gpu-runtime.sh"


def patched_hunks() -> str:
    """The patched side of every hunk: context and added lines."""
    lines = PATCH.read_text(encoding="utf-8").split("\n@@", 1)[1].splitlines()
    return "\n".join(
        line[1:]
        for line in lines
        if line[:1] in (" ", "+") and not line.startswith("+++")
    )


def block(source: str, start: str, end: str) -> str:
    begin = source.index(start)
    return source[begin:source.index(end, begin) + len(end)]


def sync_block() -> str:
    return (block(patched_hunks(), "    bool keyboard_event = ",
                  "        rightCommandGuestDown = NO;\n    }")
            .replace("[self isKeyboardCaptured]", "captured"))


HARNESS = r"""
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#define NSEventModifierFlagShift (1u << 17)
#define NSEventModifierFlagControl (1u << 18)
#define NSEventModifierFlagOption (1u << 19)
#define NSEventModifierFlagCommand (1u << 20)
#define KEY_LEFTCTRL 29
#define KEY_LEFTSHIFT 42
#define KEY_RIGHTSHIFT 54
#define KEY_LEFTALT 56
#define KEY_RIGHTCTRL 97
#define KEY_RIGHTALT 100
#define KEY_LEFTMETA 125
#define KEY_RIGHTMETA 126
#define BOOL bool
#define NO false
typedef unsigned long NSUInteger;
typedef enum {
    NSEventTypeMouseMoved,
    NSEventTypeLeftMouseDown,
    NSEventTypeLeftMouseUp,
    NSEventTypeScrollWheel,
    NSEventTypeMagnify,
    NSEventTypeKeyDown,
    NSEventTypeKeyUp,
    NSEventTypeFlagsChanged,
} NSEventType;

static bool swap_opt_cmd;
static bool captured;
static bool leftCommandGuestDown, rightCommandGuestDown;
static bool held[256];
static void *kbd;

static void qkbd_state_key_event(void *state, int key, bool down)
{
    if (held[key] == down) {
        return;
    }
    held[key] = down;
    printf(" %d%c", key, down ? '+' : '-');
}

static void sync_modifiers(NSEventType event_type, NSUInteger modifiers)
{
    bool flags_changed = event_type == NSEventTypeFlagsChanged;
@@SYNC@@
}

static void event(const char *label, NSEventType type, NSUInteger modifiers)
{
    printf(" %s", label);
    sync_modifiers(type, modifiers);
}

static void guest_down(const char *label, int key)
{
    printf(" %s", label);
    qkbd_state_key_event(kbd, key, true);
}

int main(int argc, char **argv)
{
    if (!strcmp(argv[1], "shift-click")) {
        event("shift", NSEventTypeFlagsChanged, NSEventModifierFlagShift);
        qkbd_state_key_event(kbd, KEY_LEFTSHIFT, true);
        event("move", NSEventTypeMouseMoved, 0);
        event("move", NSEventTypeMouseMoved, 0);
        event("down", NSEventTypeLeftMouseDown, 0);
        event("up", NSEventTypeLeftMouseUp, 0);
        event("shift-up", NSEventTypeFlagsChanged, 0);
    } else if (!strcmp(argv[1], "every-modifier")) {
        guest_down("shift", KEY_LEFTSHIFT);
        guest_down("ctrl", KEY_RIGHTCTRL);
        guest_down("option", KEY_LEFTALT);
        leftCommandGuestDown = true;
        guest_down("command", KEY_LEFTMETA);
        event("move", NSEventTypeMouseMoved, 0);
        event("scroll", NSEventTypeScrollWheel, 0);
        event("magnify", NSEventTypeMagnify, 0);
        event("key", NSEventTypeKeyDown, 0);
    } else if (!strcmp(argv[1], "swapped-option-command")) {
        swap_opt_cmd = true;
        guest_down("option", KEY_LEFTMETA);
        guest_down("command", KEY_LEFTALT);
        event("move", NSEventTypeMouseMoved, 0);
        event("key", NSEventTypeKeyUp, 0);
    } else if (!strcmp(argv[1], "key-flags")) {
        guest_down("shift", KEY_RIGHTSHIFT);
        event("key-with-shift", NSEventTypeKeyDown, NSEventModifierFlagShift);
        event("key-without-shift", NSEventTypeKeyUp, 0);
    }
    printf("\n");
    return 0;
}
"""


class CocoaPointerModifierTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.work = tempfile.TemporaryDirectory()
        work = Path(cls.work.name)
        (work / "sync.c").write_text(HARNESS.replace("@@SYNC@@", sync_block()))
        subprocess.run([os.environ.get("CC", "cc"), "-Wall", "-Werror", "-Wno-unused-variable",
                        "-Wno-unused-parameter", "-o", str(work / "sync"), str(work / "sync.c")],
                       check=True)

    @classmethod
    def tearDownClass(cls) -> None:
        cls.work.cleanup()

    def replay(self, scenario: str) -> str:
        return subprocess.run([str(Path(self.work.name) / "sync"), scenario], check=True,
                              capture_output=True, text=True).stdout.strip()

    def test_pinned_and_applied_after_the_korean_caps_lock_patch(self) -> None:
        builder = BUILDER.read_text()
        digest = re.search(r"^pointer_modifiers_patch_sha256=([a-f0-9]{64})$", builder, re.M)
        self.assertEqual(hashlib.sha256(PATCH.read_bytes()).hexdigest(), digest[1])
        self.assertIn('verify_file_sha "Try Omarchy Cocoa pointer modifier patch"', builder)
        applied = re.findall(r'^patch -d "\$source_dir" -p1 -f -i "\$(\w+)"$', builder, re.M)
        self.assertLess(applied.index("korean_caps_lock_patch"), applied.index("pointer_modifiers_patch"))

    def test_pointer_events_do_not_release_a_held_shift(self) -> None:
        self.assertEqual(self.replay("shift-click"), "shift 42+ move move down up shift-up 42-")

    def test_pointer_events_do_not_release_any_modifier(self) -> None:
        self.assertEqual(self.replay("every-modifier"),
                         "shift 42+ ctrl 97+ option 56+ command 125+ move scroll magnify key 42- 97- 56- 125-")

    def test_pointer_events_keep_swapped_option_and_command(self) -> None:
        self.assertEqual(self.replay("swapped-option-command"),
                         "option 125+ command 56+ move key 125- 56-")

    def test_keyboard_events_still_release_a_modifier_their_flags_lack(self) -> None:
        self.assertEqual(self.replay("key-flags"), "shift 54+ key-with-shift key-without-shift 54-")


if __name__ == "__main__":
    unittest.main()
