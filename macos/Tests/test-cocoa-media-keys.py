#!/usr/bin/env python3
"""Compile and exercise the Cocoa media-key decoder, without AppKit."""

from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "macos/patches/qemu-cocoa-media-keys.patch"
BUILDER = ROOT / "macos/build-qemu-gpu-runtime.sh"


def plus_lines() -> str:
    return "\n".join(
        line[1:]
        for line in PATCH.read_text(encoding="utf-8").splitlines()
        if line.startswith("+") and not line.startswith("+++")
    )


def extract_c_block(source: str, start: str, end: str) -> str:
    begin = source.index(start)
    finish = source.index(end, begin) + len(end)
    return source[begin:finish]


class CocoaMediaKeysTests(unittest.TestCase):
    def test_decoder_maps_transport_keys_and_ignores_the_rest(self) -> None:
        decoder = extract_c_block(
            plus_lines(),
            "static bool cocoa_media_key(long data1, int *qcode, bool *down)",
            "    return true;\n}",
        )
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / "media-keys.c").write_text(
                f"""
#include <assert.h>
#include <stdbool.h>

enum {{ Q_KEY_CODE_AUDIOPLAY = 1, Q_KEY_CODE_AUDIONEXT = 2, Q_KEY_CODE_AUDIOPREV = 3 }};

{decoder}

static long data1(long key_type, long state, int repeating) {{
    return (key_type << 16) | (state << 8) | (repeating ? 1 : 0);
}}

int main(void) {{
    int qcode = 0;
    bool down = false;
    assert(cocoa_media_key(data1(16, 0xA, 0), &qcode, &down) && qcode == Q_KEY_CODE_AUDIOPLAY && down);
    assert(cocoa_media_key(data1(16, 0xB, 0), &qcode, &down) && qcode == Q_KEY_CODE_AUDIOPLAY && !down);
    assert(cocoa_media_key(data1(17, 0xA, 0), &qcode, &down) && qcode == Q_KEY_CODE_AUDIONEXT && down);
    assert(cocoa_media_key(data1(19, 0xA, 1), &qcode, &down) && qcode == Q_KEY_CODE_AUDIONEXT && down);
    assert(cocoa_media_key(data1(18, 0xB, 0), &qcode, &down) && qcode == Q_KEY_CODE_AUDIOPREV && !down);
    assert(cocoa_media_key(data1(20, 0xA, 0), &qcode, &down) && qcode == Q_KEY_CODE_AUDIOPREV && down);
    /* volume up/down, brightness, mute, backlight */
    long ignored[] = {{0, 1, 2, 3, 7, 21, 22, 23}};
    for (unsigned i = 0; i < sizeof ignored / sizeof ignored[0]; i++) {{
        assert(!cocoa_media_key(data1(ignored[i], 0xA, 0), &qcode, &down));
    }}
    assert(!cocoa_media_key(data1(16, 0x0, 0), &qcode, &down));
    return 0;
}}
""",
                encoding="utf-8",
            )
            subprocess.run(
                ["cc", "-std=c11", "-Wall", "-Werror", "-o", str(work / "media-keys"), str(work / "media-keys.c")],
                check=True,
            )
            subprocess.run([str(work / "media-keys")], check=True)

    def test_option_mask_and_capture_guard(self) -> None:
        added = plus_lines()
        self.assertIn("'*media-keys': 'bool',", added)
        self.assertIn("[,media-keys=on|off]", added)
        self.assertIn("static bool media_keys_enabled;", added)
        self.assertIn("[view isKeyboardCaptured]", added)
        self.assertIn("cocoa_media_key(", added)
        self.assertIn("qemu_input_map_qcode_to_linux[qcode]", added)
        self.assertIn("mask |= CGEventMaskBit(14", added)

    def test_runtime_applies_it_after_host_keys(self) -> None:
        builder = BUILDER.read_text(encoding="utf-8")
        host_keys = builder.index('patch -d "$source_dir" -p1 -f -i "$host_keys_patch"')
        media_keys = builder.index('patch -d "$source_dir" -p1 -f -i "$media_keys_patch"')
        self.assertLess(host_keys, media_keys)
        self.assertIn('verify_file_sha "Try Omarchy Cocoa media-keys patch"', builder)


if __name__ == "__main__":
    unittest.main()
