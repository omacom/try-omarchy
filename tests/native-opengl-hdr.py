#!/usr/bin/env python3
"""Compile and exercise the shipped native HDR shader and a real Cocoa float layer."""
import pathlib
import re
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
patch = (root / "macos/patches/qemu-cocoa-native-hdr.patch").read_text()
block = next(block for block in re.split(r"(?=^diff --git )", patch, flags=re.M)
             if block.startswith("diff --git a/ui/cocoa-gl-hdr.h "))
header = "\n".join(line[1:] for line in block.splitlines()
                   if line.startswith("+") and not line.startswith("+++")) + "\n"
with tempfile.TemporaryDirectory(prefix="omarchy-native-hdr-") as temporary:
    directory = pathlib.Path(temporary)
    (directory / "cocoa-gl-hdr.h").write_text(header)
    executable = directory / "native-hdr-test"
    subprocess.run(["xcrun", "clang", "-std=gnu11", "-fblocks", "-I", str(directory),
                    str(root / "tests/native-opengl-hdr.m"), "-o", str(executable),
                    "-framework", "AppKit", "-framework", "QuartzCore", "-framework", "OpenGL"], check=True)
    subprocess.run([str(executable)], check=True)
