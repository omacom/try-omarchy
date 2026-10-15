#!/usr/bin/env python3
"""Compile the Cocoa Command-chord logic without AppKit and replay chords."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "macos/patches/qemu-cocoa-command-chord-hold.patch"
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


def as_c(objc: str) -> str:
    return (objc.replace("[self isKeyboardCaptured]", "captured")
                .replace("[self setCommandKey:false down:down]", "set_command_key(false, down)")
                .replace("[self setCommandKey:true down:down]", "set_command_key(true, down)"))


HARNESS = r"""
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#define NSEventModifierFlagCommand (1u << 20)
#define KEY_LEFTALT 56
#define KEY_RIGHTALT 100
#define KEY_LEFTMETA 125
#define KEY_RIGHTMETA 126
#define KEY_C 46
#define BOOL bool
#define NO false
typedef unsigned long NSUInteger;

static bool swap_opt_cmd;
static int left_command_key_enabled = 1;
static bool captured;
static bool leftCommandGuestDown, rightCommandGuestDown;
static bool held[256];

static void qkbd_state_key_event(void *kbd, int key, bool down)
{
    if (held[key] == down) {
        return;
    }
    held[key] = down;
    printf("%d%c ", key, down ? '+' : '-');
}
static void *kbd;

@@DEFINES@@

@@SETTER@@

static void sync(NSUInteger modifiers)
{
@@SYNC@@
}

static void flags_changed(int key, NSUInteger modifiers)
{
    sync(modifiers);
    switch (key) {
@@CASES@@
    }
}

static void key(int code, bool down, NSUInteger modifiers)
{
    sync(modifiers);
    /* Uncaptured Command chords stay with the host (handleEventLocked:). */
    if (!captured && (modifiers & NSEventModifierFlagCommand)) {
        return;
    }
    qkbd_state_key_event(kbd, code, down);
}

int main(int argc, char **argv)
{
    const NSUInteger cmd_l = NSEventModifierFlagCommand | COCOA_DEVICE_LEFT_COMMAND;
    if (!strcmp(argv[1], "captured-chord")) {
        /* The tap hides Command from the chord key's flags. */
        captured = true;
        flags_changed(kVK_Command, cmd_l);
        key(KEY_C, true, 0);
        key(KEY_C, false, 0);
        flags_changed(kVK_Command, 0);
    } else if (!strcmp(argv[1], "generic-flag")) {
        /* Posted events can carry Command without a device bit. */
        captured = true;
        flags_changed(kVK_Command, NSEventModifierFlagCommand);
        key(KEY_C, true, 0);
        key(KEY_C, false, 0);
        flags_changed(kVK_Command, 0);
    } else if (!strcmp(argv[1], "uncaptured")) {
        flags_changed(kVK_Command, cmd_l);
        key(KEY_C, true, cmd_l);
    } else if (!strcmp(argv[1], "release-after-focus-loss")) {
        captured = true;
        flags_changed(kVK_Command, cmd_l);
        captured = false;
        flags_changed(kVK_Command, 0);
        flags_changed(kVK_Command, 0);
    }
    printf("\n");
    return 0;
}
"""


class CocoaCommandChordTests(unittest.TestCase):
    def test_pinned_and_applied_after_the_other_cocoa_patches(self) -> None:
        builder = BUILDER.read_text()
        digest = re.search(r"^command_chord_patch_sha256=([a-f0-9]{64})$", builder, re.M)
        self.assertEqual(hashlib.sha256(PATCH.read_bytes()).hexdigest(), digest[1])
        self.assertIn('"$command_chord_patch" "$command_chord_patch_sha256"', builder)
        chord = builder.index('patch -d "$source_dir" -p1 -f -i "$command_chord_patch"')
        for earlier in ("iso_swap_patch", "injected_text_patch"):
            self.assertLess(builder.index(f'patch -d "$source_dir" -p1 -f -i "${earlier}"'), chord)

    def replay(self, scenario: str) -> str:
        added = patched_hunks()
        source = (HARNESS
                  .replace("@@DEFINES@@", block(added, "#define COCOA_DEVICE_LEFT_COMMAND",
                                                "    return modifiers & NSEventModifierFlagCommand;\n}")
                           + "\n#define kVK_Command 0x37\n#define kVK_RightCommand 0x36")
                  .replace("@@SETTER@@", "static void set_command_key(bool right, bool down)\n"
                           + block(added, "{\n    unsigned int keycode = swap_opt_cmd", "    }\n}")[0:])
                  .replace("@@SYNC@@", as_c(block(
                      added, "    if (!(modifiers & NSEventModifierFlagCommand) &&",
                      "        rightCommandGuestDown = NO;\n    }")))
                  .replace("@@CASES@@", as_c(block(
                      added, "                case kVK_Command: {",
                      "                        [self setCommandKey:true down:down];\n"
                      "                    }\n                    break;\n                }"))))
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / "chord.c").write_text(source)
            subprocess.run([os.environ.get("CC", "cc"), "-Wall", "-Werror", "-Wno-unused-variable", "-o",
                            str(work / "chord"), str(work / "chord.c")], check=True)
            return subprocess.run([str(work / "chord"), scenario], check=True,
                                  capture_output=True, text=True).stdout.strip()

    def test_captured_chord_holds_super_until_command_is_released(self) -> None:
        self.assertEqual(self.replay("captured-chord"), "125+ 46+ 46- 125-")

    def test_uncaptured_command_chord_stays_with_the_host(self) -> None:
        self.assertEqual(self.replay("uncaptured"), "")

    def test_command_without_a_device_bit_still_holds_super(self) -> None:
        self.assertEqual(self.replay("generic-flag"), "125+ 46+ 46- 125-")

    def test_release_reaches_the_guest_after_capture_ends(self) -> None:
        self.assertEqual(self.replay("release-after-focus-loss"), "125+ 125-")


if __name__ == "__main__":
    unittest.main()
