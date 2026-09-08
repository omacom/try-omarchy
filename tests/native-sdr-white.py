#!/usr/bin/env python3
"""Exercise the actual Cocoa SDR-cap reader without changing display settings."""
import pathlib
import re
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
patch = (ROOT / "macos/patches/qemu-cocoa-sdr-white.patch").read_text()
block = next(block for block in re.split(r"(?=^diff --git )", patch, flags=re.M)
             if block.startswith("diff --git a/ui/cocoa-sdr-white.h "))
assert "--- /dev/null\n" in block
header = "\n".join(line[1:] for line in block.splitlines()
                   if line.startswith("+") and not line.startswith("+++")) + "\n"
with tempfile.TemporaryDirectory(prefix="omarchy-sdr-white-") as temporary:
    directory = pathlib.Path(temporary)
    (directory / "cocoa-sdr-white.h").write_text(header)
    (directory / "check.m").write_text(r'''
#include "cocoa-sdr-white.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    @autoreleasepool {
        struct { double nits; uint32_t expected; } cases[] = {
            {500, 500}, {600, 600}, {1000, 1000}, {100, 100},
            {1, 1}, {1600, 1000}, {0, 0}, {-600, 0},
            {10001, 0}, {NAN, 0}, {INFINITY, 0}
        };
        for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
            NSDictionary *value = @{@"PresetValid": @YES,
                @"PresetMaxSDRLuminance": @(cases[i].nits)};
            assert(cocoa_sdr_nits_from_preset((CFDictionaryRef)value)
                   == cases[i].expected);
        }
        assert(cocoa_sdr_nits_from_preset(NULL) == 0);
        assert(cocoa_sdr_nits_from_preset((CFDictionaryRef)CFSTR("600")) == 0);
        NSArray *invalid = @[
            @{@"PresetValid": @NO, @"PresetMaxSDRLuminance": @600},
            @{@"PresetValid": @1, @"PresetMaxSDRLuminance": @600},
            @{@"PresetMaxSDRLuminance": @600},
            @{@"PresetValid": @YES, @"PresetMaxSDRLuminance": @YES},
            @{@"PresetValid": @YES, @"PresetMaxSDRLuminance": @"600"},
            @{@"PresetValid": @YES, @"PresetMaxHDRLuminance": @1600}
        ];
        for (NSDictionary *value in invalid) {
            assert(cocoa_sdr_nits_from_preset((CFDictionaryRef)value) == 0);
        }
        NSDictionary *independent = @{@"PresetValid": @YES,
            @"PresetMaxSDRLuminance": @600, @"PresetMaxHDRLuminance": @1600};
        assert(cocoa_sdr_nits_from_preset((CFDictionaryRef)independent) == 600);
        assert(cocoa_sdr_white_nits(nil) == 0);
        for (NSScreen *screen in NSScreen.screens) {
            NSNumber *number = screen.deviceDescription[@"NSScreenNumber"];
            uint32_t nits = cocoa_sdr_white_nits(screen);
            printf("display=%u builtin=%d sdrWhiteNits=%u\n",
                number.unsignedIntValue,
                CGDisplayIsBuiltin(number.unsignedIntValue), nits);
        }
        puts("SDR-cap conversion and host query passed");
    }
}
''')
    binary = directory / "check"
    subprocess.run(["clang", "-std=gnu11", "-fblocks", "-Wall", "-Wextra", "-Werror",
                    "-mmacosx-version-min=15.0", "-Werror=unguarded-availability-new",
                    str(directory / "check.m"), "-o", str(binary),
                    "-framework", "AppKit"], check=True)
    subprocess.run([str(binary)], check=True)
