#!/usr/bin/env python3
"""Compile and exercise the Cocoa host-keys parser, without AppKit."""

from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "macos/patches/qemu-cocoa-host-keys.patch"
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


class CocoaHostKeysTests(unittest.TestCase):
    def test_parser_accepts_colon_lists_and_rejects_everything_else(self) -> None:
        parser = extract_c_block(
            plus_lines(),
            "static bool cocoa_parse_host_keys(const char *spec, bool host_keys[256])",
            "        cursor++;\n    }\n}",
        )
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / "host-keys.c").write_text(
                f"""
#include <assert.h>
#include <stdbool.h>
#include <string.h>

{parser}

static int count(const bool table[256]) {{
    int total = 0;
    for (int i = 0; i < 256; i++) total += table[i];
    return total;
}}

int main(void) {{
    bool table[256];
    assert(cocoa_parse_host_keys("", table) && count(table) == 0);
    assert(cocoa_parse_host_keys("144", table) && table[144] && count(table) == 1);
    assert(cocoa_parse_host_keys("131:144:145:160", table));
    assert(table[131] && table[144] && table[145] && table[160] && count(table) == 4);
    assert(cocoa_parse_host_keys("0:255", table) && table[0] && table[255]);
    assert(!cocoa_parse_host_keys("256", table));
    assert(!cocoa_parse_host_keys("1234", table));
    assert(!cocoa_parse_host_keys("144,145", table));
    assert(!cocoa_parse_host_keys(":144", table));
    assert(!cocoa_parse_host_keys("144:", table));
    assert(!cocoa_parse_host_keys("144::145", table));
    assert(!cocoa_parse_host_keys("abc", table));
    return 0;
}}
""",
                encoding="utf-8",
            )
            subprocess.run(
                ["cc", "-std=c11", "-Wall", "-Werror", "-o", str(work / "host-keys"), str(work / "host-keys.c")],
                check=True,
            )
            subprocess.run([str(work / "host-keys")], check=True)

    def test_tap_and_window_paths_both_leave_host_keys_alone(self) -> None:
        added = plus_lines()
        self.assertIn("'*host-keys': 'str',", added)
        self.assertIn("[,host-keys=code:code...]", added)
        self.assertIn("return keycode < 256 && cocoa_host_keys[keycode];", added)
        patch = PATCH.read_text(encoding="utf-8")
        tap_guard = patch.index("cocoa_is_host_key(CGEventGetIntegerValueField(cgEvent,")
        conversion = patch.index("NSEvent *event = [NSEvent eventWithCGEvent:cgEvent];")
        self.assertLess(tap_guard, conversion)
        self.assertEqual(patch.count("if (cocoa_is_host_key([event keyCode])) {"), 2)

    def test_runtime_applies_it_after_the_tap_recovery(self) -> None:
        builder = BUILDER.read_text(encoding="utf-8")
        reenable = builder.index('patch -d "$source_dir" -p1 -f -i "$reenable_patch"')
        host_keys = builder.index('patch -d "$source_dir" -p1 -f -i "$host_keys_patch"')
        self.assertLess(reenable, host_keys)
        self.assertIn('verify_file_sha "Try Omarchy Cocoa host-keys patch"', builder)


if __name__ == "__main__":
    unittest.main()
