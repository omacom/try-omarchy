#!/usr/bin/env python3
"""Check the Cocoa immersive-mode and return-to-macOS shortcut patch."""

from __future__ import annotations

import hashlib
from pathlib import Path
import platform
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "macos/patches/qemu-cocoa-immersive-hotkeys.patch"
BUILDER = ROOT / "macos/build-qemu-gpu-runtime.sh"
HARNESS = ROOT / "macos/Tests/cocoa-immersive-hotkeys-harness.m"


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


def braced(source: str, marker: str) -> str:
    start = source.index(marker)
    depth, end = 1, source.index("{", start) + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def method_name(line: str) -> str | None:
    match = re.match(r"- \(\w+\) ?(\w+):", line)
    return match[1] if match else None


def added_statements(name: str) -> str:
    """The lines the patch adds to an Objective-C method, which may also have
    upstream lines the patch leaves alone."""
    current, statements = None, []
    for line in body():
        if line.startswith("@@"):
            current = method_name(line.split("@@", 2)[2].strip())
        elif line[:1] in (" ", "+"):
            text = line[1:]
            if text.startswith("- ("):
                current = method_name(text)
            elif text.startswith(("@end", "static ")):
                current = None
            elif line.startswith("+") and current == name and text.startswith("    "):
                statements.append(text)
    if not statements:
        raise AssertionError(f"the patch adds nothing to {name}")
    return "\n".join(statements)


def harness() -> str:
    text = added()
    state = "\n".join(line for line in text.splitlines() if re.fullmatch(r"static .*;", line))
    functions = "\n\n".join(braced(text, signature) for signature in (
        "static void cocoa_set_immersive(bool enabled)\n",
        "static void cocoa_fullscreen_transition_failed(void)\n",
        "static void cocoa_toggle_immersive(void)\n",
        "static void cocoa_return_to_host(void)\n",
    ))
    delegate = "\n".join(f"- (void){name}:(id)sender\n{{\n{added_statements(name)}\n}}" for name in (
        "windowWillEnterFullScreen", "windowDidEnterFullScreen",
        "windowDidFailToEnterFullScreen", "windowWillExitFullScreen",
        "windowDidExitFullScreen", "windowDidFailToExitFullScreen", "toggleImmersive",
    ))
    source = HARNESS.read_text(encoding="utf-8")
    for marker, code in (("/* STATE */", state),
                         ("/* KEYS */", braced(text, "if ([event keyCode] == kVK_Escape) {")),
                         ("/* FUNCTIONS */", functions), ("/* DELEGATE */", delegate)):
        source = source.replace(marker, code)
    return source


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

    def test_shortcuts_act_outside_the_bql_and_ignore_repeats(self) -> None:
        source = hunk_with("// handle control + alt Key Combos")
        table = source[source.index("// handle control + alt Key Combos"):source.index("switch (key)")]
        self.assertEqual(table.count("![event isARepeat]"), 1)
        self.assertEqual(table.count("dispatch_async(dispatch_get_main_queue()"), 1)
        self.assertIn("cocoa_return_to_host();", table)
        self.assertIn("cocoa_toggle_immersive();", table)

    @unittest.skipUnless(platform.system() == "Darwin", "requires Objective-C Foundation")
    def test_shortcuts_switch_hide_and_recover_in_the_harness(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source, binary = Path(directory) / "test.m", Path(directory) / "test"
            source.write_text(harness(), encoding="utf-8")
            subprocess.run(["xcrun", "clang", "-fobjc-arc", "-Werror", "-framework", "Foundation",
                            str(source), "-o", str(binary)], check=True)
            subprocess.run([str(binary)], check=True)

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
