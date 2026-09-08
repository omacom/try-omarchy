#!/usr/bin/env python3
"""Check the actual Cocoa HDR shader and ANGLE-to-Metal GPU handoff on macOS."""
import argparse
import pathlib
import re
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--angle-include", type=pathlib.Path, required=True)
parser.add_argument("--epoxy-include", type=pathlib.Path, required=True)
parser.add_argument("--runtime", type=pathlib.Path, default=ROOT/"macos/.build/qemu-gpu-runtime")
args = parser.parse_args()
patch = (ROOT/"macos/patches/qemu-cocoa-hdr.patch").read_text()
required = {"ui/cocoa-hdr.m", "ui/cocoa-hdr.h", "include/ui/hdr.h"}
with tempfile.TemporaryDirectory(prefix="omarchy-hdr-test-") as temporary:
    source = pathlib.Path(temporary)
    found = set()
    for block in re.split(r"(?=^diff --git )", patch, flags=re.M):
        if not block.startswith("diff --git "):
            continue
        name = block.splitlines()[0].split(" b/", 1)[1]
        if name not in required:
            continue
        assert "--- /dev/null\n" in block, name
        added = "\n".join(line[1:] for line in block.splitlines()
                          if line.startswith("+") and not line.startswith("+++"))+"\n"
        target = source/name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(added)
        found.add(name)
    assert found == required
    executable = source/"presenter-test"
    libraries = args.runtime.resolve()/"lib"
    subprocess.run(["clang", "-std=gnu11", "-fblocks",
                    "-I"+str(source), "-I"+str(source/"include"),
                    "-I"+str(args.angle_include), "-I"+str(args.epoxy_include),
                    str(ROOT/"tests/native-hdr-presenter.m"), "-o", str(executable),
                    "-L"+str(libraries), "-Wl,-rpath,"+str(libraries),
                    "-lEGL", "-lGLESv2", "-lepoxy.0",
                    "-framework", "AppKit", "-framework", "CoreVideo", "-framework", "IOSurface",
                    "-framework", "Metal", "-framework", "QuartzCore"], check=True)
    subprocess.run([str(executable)], check=True)
