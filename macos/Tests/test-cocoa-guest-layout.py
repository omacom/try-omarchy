#!/usr/bin/env python3
"""Checksum, wire and compile the Cocoa guest-layout pointer, without QEMU."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "macos/patches/qemu-cocoa-guest-layout.patch"
BUILDER = ROOT / "macos/build-qemu-gpu-runtime.sh"
LAUNCHER = ROOT / "macos/run-qemu-gpu.sh"
REPORTER = ROOT / "guest/package/try-omarchy/files/usr/lib/try-omarchy/display-report"


def added() -> str:
    return "\n".join(
        line[1:]
        for line in PATCH.read_text(encoding="utf-8").splitlines()
        if line.startswith("+") and not line.startswith("+++")
    )


class CocoaGuestLayoutTests(unittest.TestCase):
    def test_builder_verifies_and_applies_the_exact_patch_after_the_display_patches(self) -> None:
        builder = BUILDER.read_text(encoding="utf-8")
        expected = re.search(r"^guest_layout_patch_sha256=([a-f0-9]{64})$", builder, re.M)
        self.assertIsNotNone(expected)
        self.assertEqual(hashlib.sha256(PATCH.read_bytes()).hexdigest(), expected.group(1))
        self.assertIn('verify_file_sha "Try Omarchy Cocoa guest-layout patch"', builder)
        applied = re.findall(r'^patch -d "\$source_dir" -p1 -f -i "\$(\w+)"$', builder, re.M)
        # Only the immersive-hotkeys patch, made against this one, comes later.
        self.assertEqual(applied[applied.index("guest_layout_patch") + 1:], ["immersive_hotkeys_patch"])

    def test_the_launcher_serves_the_port_qemu_reads(self) -> None:
        launcher = LAUNCHER.read_text(encoding="utf-8")
        self.assertIn('-chardev "socket,id=omarchy-display-layout,path=$display_socket,server=on,wait=off"', launcher)
        self.assertIn("nr=9,chardev=omarchy-display-layout,name=dev.tryomarchy.display", launcher)
        self.assertIn("export TRYOMARCHY_DISPLAY_SOCKET=$display_socket", launcher)
        self.assertIn('getenv("TRYOMARCHY_DISPLAY_SOCKET")', added())
        self.assertIn("/dev/virtio-ports/dev.tryomarchy.display", REPORTER.read_text(encoding="utf-8"))

    def test_the_pointer_falls_back_to_the_macs_arrangement(self) -> None:
        code = added()
        self.assertIn("if (!cocoa_guest_layout_point(head->index, fx, fy, &dx, &dy)) {\n"
                      "                desktop = cocoa_desktop_rect();", code)
        # A guest reset forgets the layout until the next desktop reports one.
        self.assertIn("qemu_register_reset(cocoa_guest_layout_reset, NULL);", code)
        self.assertIn("        guest_output_count = 0;\n", code)

    def test_reports_are_checked_mapped_and_read_from_a_stream(self) -> None:
        code = added()
        start = code.index("#define COCOA_GUEST_OUTPUTS")
        functions = code[start:code.index("static void cocoa_guest_layout_connect(void);")]
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            source = work / "layout.m"
            source.write_text(
                f"""
#import <Foundation/Foundation.h>
#include <assert.h>
#include <math.h>

#define COCOA_MAX_HEADS 4
#define COCOA_MAX_DESKTOP 99999
static unsigned warnings;
#define warn_report(...) (warnings++)

{functions}

static unsigned parse(const char *text)
{{
    NSData *line = [NSData dataWithBytes:text length:strlen(text)];
    unsigned count = cocoa_guest_layout_parse(line, guest_outputs);

    guest_output_count = count;
    return count;
}}

static void receive(const char *bytes)
{{
    cocoa_guest_layout_receive((const uint8_t *)bytes, strlen(bytes));
}}

static CGFloat width_of(unsigned output)
{{
    for (unsigned i = 0; i < guest_output_count; i++) {{
        if (guest_outputs[i].head_output == output) {{
            return NSWidth(guest_outputs[i].rect);
        }}
    }}
    return 0;
}}

static bool near(CGFloat a, CGFloat b)
{{
    return fabs(a - b) < 1e-9;
}}

int main(void)
{{
    CGFloat x, y;

    @autoreleasepool {{
        /* A 5K display above a MacBook panel the person set to scale 1.6. */
        assert(parse("{{\\"outputs\\":[{{\\"name\\":\\"Virtual-1\\",\\"x\\":512,\\"y\\":1440,"
                     "\\"width\\":1890,\\"height\\":1227.5}},"
                     "{{\\"name\\":\\"Virtual-2\\",\\"x\\":0,\\"y\\":0,\\"width\\":2560,\\"height\\":1440}}]}}") == 2);
        assert(cocoa_guest_layout_point(0, 0, 0, &x, &y));
        assert(near(x, 512.0 / 2560) && near(y, 1440 / 2667.5));
        assert(cocoa_guest_layout_point(0, 1, 1, &x, &y));
        assert(near(x, 2402.0 / 2560) && near(y, 1));
        assert(cocoa_guest_layout_point(1, 0.5, 0.5, &x, &y));
        assert(near(x, 0.5) && near(y, 720 / 2667.5));
        /* No head shows a third output. */
        assert(!cocoa_guest_layout_point(2, 0.5, 0.5, &x, &y));

        /* Another output, such as a headless one, still widens the desktop. */
        assert(parse("{{\\"outputs\\":[{{\\"name\\":\\"Virtual-1\\",\\"x\\":0,\\"y\\":0,\\"width\\":1000,\\"height\\":500}},"
                     "{{\\"name\\":\\"HEADLESS-2\\",\\"x\\":1000,\\"y\\":0,\\"width\\":1000,\\"height\\":500}}]}}") == 2);
        assert(cocoa_guest_layout_point(0, 1, 1, &x, &y));
        assert(near(x, 0.5) && near(y, 1));

        /* Anything else is dropped whole. */
        const char *rejected[] = {{
            "",
            "not json",
            "[]",
            "{{\\"outputs\\":[]}}",
            "{{\\"outputs\\":{{}}}}",
            "{{\\"outputs\\":[1]}}",
            "{{\\"outputs\\":[{{\\"name\\":\\"Virtual-1\\",\\"x\\":0,\\"y\\":0,\\"width\\":0,\\"height\\":500}}]}}",
            "{{\\"outputs\\":[{{\\"name\\":\\"Virtual-1\\",\\"x\\":0,\\"y\\":0,\\"width\\":-5,\\"height\\":500}}]}}",
            "{{\\"outputs\\":[{{\\"name\\":\\"Virtual-1\\",\\"x\\":true,\\"y\\":0,\\"width\\":10,\\"height\\":500}}]}}",
            "{{\\"outputs\\":[{{\\"name\\":\\"Virtual-1\\",\\"x\\":\\"0\\",\\"y\\":0,\\"width\\":10,\\"height\\":500}}]}}",
            "{{\\"outputs\\":[{{\\"name\\":\\"Virtual-1\\",\\"x\\":1e300,\\"y\\":0,\\"width\\":10,\\"height\\":500}}]}}",
            "{{\\"outputs\\":[{{\\"name\\":\\"Virtual-1\\",\\"y\\":0,\\"width\\":10,\\"height\\":500}}]}}",
            "{{\\"outputs\\":[{{\\"name\\":7,\\"x\\":0,\\"y\\":0,\\"width\\":10,\\"height\\":500}}]}}",
            "{{\\"outputs\\":[{{\\"name\\":\\"Virtual-1\\",\\"x\\":0,\\"y\\":0,\\"width\\":10,\\"height\\":500}},"
            "{{\\"name\\":\\"Virtual-1\\",\\"x\\":10,\\"y\\":0,\\"width\\":10,\\"height\\":500}}]}}",
            "{{\\"outputs\\":[{{\\"name\\":\\"Virtual-1-and-a-very-long-name-past-the-limit\\",\\"x\\":0,\\"y\\":0,"
            "\\"width\\":10,\\"height\\":500}}]}}",
        }};
        for (size_t i = 0; i < sizeof(rejected) / sizeof(rejected[0]); i++) {{
            assert(parse(rejected[i]) == 0);
        }}
        /* More outputs than any Mac has displays. */
        NSMutableString *many = [NSMutableString stringWithString:@"{{\\"outputs\\":["];
        for (int i = 0; i < 9; i++) {{
            [many appendFormat:@"%@{{\\"name\\":\\"O-%d\\",\\"x\\":0,\\"y\\":0,\\"width\\":1,\\"height\\":1}}", i ? @"," : @"", i];
        }}
        [many appendString:@"]}}"];
        assert(parse([many UTF8String]) == 0);
        /* Without a layout, the Mac's arrangement applies. */
        assert(!cocoa_guest_layout_point(0, 0.5, 0.5, &x, &y));

        /* The port delivers bytes: a report in pieces applies once whole. */
        receive("{{\\"outputs\\":[{{\\"name\\":\\"Virtual-1\\",\\"x\\":0,");
        assert(guest_output_count == 0);
        receive("\\"y\\":0,\\"width\\":100,\\"height\\":50}}]}}\\n");
        assert(guest_output_count == 1 && width_of(1) == 100);
        /* Several in one read: the last one stands. */
        receive("{{\\"outputs\\":[{{\\"name\\":\\"Virtual-1\\",\\"x\\":0,\\"y\\":0,\\"width\\":200,\\"height\\":50}}]}}\\n"
                "{{\\"outputs\\":[{{\\"name\\":\\"Virtual-1\\",\\"x\\":0,\\"y\\":0,\\"width\\":300,\\"height\\":50}}]}}\\n");
        assert(width_of(1) == 300);
        /* A bad report keeps the last good layout, and warns once. */
        warnings = 0;
        receive("nonsense\\nmore nonsense\\n");
        assert(width_of(1) == 300 && warnings == 1);
        /* An over-long line is skipped to its end, then reading goes on. */
        NSMutableString *flood = [NSMutableString stringWithString:@"{{\\"outputs\\":["];
        while ([flood length] < 3 * COCOA_GUEST_LAYOUT_LINE) {{
            [flood appendString:@"{{\\"name\\":\\"Virtual-1\\",\\"x\\":0,\\"y\\":0,\\"width\\":999,\\"height\\":50}},"];
        }}
        for (NSUInteger i = 0; i < [flood length]; i += 700) {{
            NSString *piece = [flood substringWithRange:NSMakeRange(i, MIN(700, [flood length] - i))];
            receive([piece UTF8String]);
        }}
        receive("]}}\\n{{\\"outputs\\":[{{\\"name\\":\\"Virtual-2\\",\\"x\\":0,\\"y\\":0,\\"width\\":400,\\"height\\":50}}]}}\\n");
        assert(guest_output_count == 1 && width_of(2) == 400 && width_of(1) == 0);
        (void)guest_layout_source;
    }}
    return 0;
}}
""",
                encoding="utf-8",
            )
            compiler = shlex.split(os.environ.get("CC", "cc"))
            binary = work / "layout"
            subprocess.run(
                compiler + ["-fno-objc-arc", "-Wall", "-Wextra", "-Werror", str(source),
                            "-framework", "Foundation", "-o", str(binary)],
                check=True,
            )
            subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    unittest.main()
