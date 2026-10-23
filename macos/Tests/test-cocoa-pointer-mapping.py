#!/usr/bin/env python3
"""Check the Cocoa pointer mapping and window size patch."""

from __future__ import annotations

import hashlib
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "macos/patches/qemu-cocoa-pointer-mapping.patch"
BUILDER = ROOT / "macos/build-qemu-gpu-runtime.sh"


def lines(prefix: str) -> str:
    return "\n".join(
        line[1:]
        for line in PATCH.read_text(encoding="utf-8").splitlines()
        if line.startswith(prefix) and not line.startswith(prefix * 3)
    )


def patched() -> str:
    """The patched side of every hunk: context and added lines."""
    text = PATCH.read_text(encoding="utf-8").splitlines()
    body = text[next(i for i, line in enumerate(text) if line.startswith("@@")):]
    return "\n".join(line[1:] for line in body if line[:1] in (" ", "+"))


class CocoaPointerMappingTests(unittest.TestCase):
    def test_builder_pins_and_applies_the_patch_before_only_the_pointer_modifier_patch(self) -> None:
        builder = BUILDER.read_text(encoding="utf-8")
        digest = hashlib.sha256(PATCH.read_bytes()).hexdigest()
        self.assertIn(f"pointer_mapping_patch_sha256={digest}", builder)
        self.assertIn('verify_file_sha "Try Omarchy Cocoa pointer-mapping patch"', builder)
        applied = re.findall(r'^patch -d "\$source_dir" -p1 -f -i "\$(\w+)"$', builder, re.MULTILINE)
        self.assertEqual(applied[applied.index("pointer_mapping_patch") + 1:], ["pointer_modifiers_patch"])

    def test_absolute_pointer_maps_each_axis_in_view_coordinates(self) -> None:
        added, removed = lines("+"), lines("-")
        self.assertIn("[self convertPoint:[event locationInWindow] fromView:nil]", added)
        self.assertIn("(p.x - NSMinX(bounds)) * screen.width / NSWidth(bounds)", added)
        self.assertIn("(NSMaxY(bounds) - p.y) * screen.height / NSHeight(bounds)", added)
        self.assertIn("CGFloat d = (CGFloat)screen.height / [self frame].size.height;", removed)
        self.assertNotIn("p.x * d", added)

    def test_guest_cursor_uses_the_height_ratio_vertically(self) -> None:
        added = lines("+")
        self.assertIn("CGFloat scaleY = [self bounds].size.height / screen.height;", added)
        self.assertIn("position.y = (screen.height - mouseY) * scaleY;", added)

    def test_resizable_window_keeps_its_size_above_the_guest_minimum(self) -> None:
        source = patched()
        start = source.index("- (void) resizeWindow")
        branch = source[start:source.index("return;", start)]
        self.assertIn("NSWindowStyleMaskResizable", branch)
        self.assertIn("!(styleMask & NSWindowStyleMaskFullScreen)", branch)
        self.assertIn("setContentResizeIncrements:NSMakeSize(1, 1)", branch)
        self.assertIn("setContentMinSize:cocoa_guest_frame_size(", branch)
        self.assertIn("[self updateUIInfo];", branch)
        self.assertNotIn("setContentSize", branch)

    def test_initial_guest_size_is_in_pixels(self) -> None:
        added = lines("+")
        self.assertIn("screen.width = frameRect.size.width * initialScale;", added)
        self.assertIn("screen.height = frameRect.size.height * initialScale;", added)


if __name__ == "__main__":
    unittest.main()
