#!/usr/bin/env python3
"""Build the format regression against the pinned renderer's compile flags."""
import json
from pathlib import Path
import shlex
import subprocess
import sys

build, output = map(lambda value: Path(value).resolve(), sys.argv[1:3])
output.mkdir(parents=True, exist_ok=True)
entries = json.loads((build / "compile_commands.json").read_text())
def run_test(name, implementation):
    entry = next(item for item in entries if item["file"].endswith("/" + implementation))
    command = entry.get("arguments") or shlex.split(entry["command"])
    directory = Path(entry["directory"])
    source = (directory / entry["file"]).resolve().parents[1]
    flags = []
    i = 1
    while i < len(command):
        flag = command[i]
        if flag in ("-o", "-MF", "-MQ", "-MT"):
            i += 2
            continue
        if flag not in ("-c", "-MD", "-MMD") and not flag.endswith("/" + implementation):
            flags.append(flag)
        i += 1
    binary = output / name
    link_args = sys.argv[3:]
    if link_args[:1] == ["--"]:
        link_args = link_args[1:]
    subprocess.run([command[0], *flags, "-I" + str(source),
                    str(Path(__file__).with_name(name + ".c")),
                    str(build / "src/libvirgl.a"), str(build / "src/gallium/libgallium.a"),
                    str(build / "src/mesa/libmesa.a"), *link_args, "-o", str(binary)],
                   cwd=directory, check=True)
    subprocess.run([str(binary)], check=True)


run_test("test-multisample-formats", "vrend_formats.c")
run_test("test-native-shader-inputs", "vrend_renderer.c")
