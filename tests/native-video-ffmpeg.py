#!/usr/bin/env python3
"""Run inside the guest: compare VA-API pixels and timing with software FFmpeg."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import time


def run(command, log, environment):
    started = time.monotonic()
    with log.open("w") as output:
        subprocess.run(command, env=environment, stdout=output,
                       stderr=subprocess.STDOUT, check=True, timeout=180)
    text = log.read_text()
    timing = re.search(r"bench: utime=([\d.]+)s stime=([\d.]+)s rtime=([\d.]+)s", text)
    counts = re.findall(r"frame=\s*(\d+)", text)
    if timing is None or not counts:
        raise RuntimeError(f"Missing FFmpeg benchmark result: {log}")
    user, system, wall = map(float, timing.groups())
    frames = int(counts[-1])
    return {"frames": frames, "wallSeconds": wall, "cpuSeconds": user + system,
            "fps": frames / wall, "processSeconds": time.monotonic() - started}


def frame_rows(path):
    return [tuple(part.strip() for part in line.split(","))
            for line in path.read_text().splitlines() if line and not line.startswith("#")]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", nargs="+", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--frames", type=int, default=120)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--device", default="/dev/dri/renderD128")
    args = parser.parse_args()
    if args.frames < 1 or args.repeats < 1:
        parser.error("frames and repeats must be positive")
    if len({p.stem for p in args.inputs}) != len(args.inputs):
        parser.error("input filenames must have distinct stems")
    if any(not p.is_file() for p in args.inputs):
        parser.error("all inputs must be existing media files")
    args.output.mkdir(parents=True, exist_ok=False)
    environment = dict(os.environ, LIBVA_DRIVER_NAME="omarchy",
                       LIBVA_DRIVERS_PATH="/usr/lib/dri", OMARCHY_VIDEO_LOG="1")
    # Scope the private, ABI-compatible libraries to these verification processes.
    environment["LD_LIBRARY_PATH"] = "/usr/local/lib/omarchy-video/ffmpeg/lib"
    version = subprocess.check_output(["/usr/bin/ffmpeg", "-version"],
                                     env=environment, text=True)
    report = {"ffmpegVersion": version, "cases": [], "driverSha256": hashlib.sha256(
        Path("/usr/lib/dri/omarchy_drv_video.so").read_bytes()).hexdigest()}
    common = ["/usr/bin/ffmpeg", "-hide_banner", "-nostdin", "-nostats", "-benchmark"]
    for source in args.inputs:
        probe = json.loads(subprocess.check_output([
            "/usr/bin/ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=codec_name,pix_fmt,width,height,r_frame_rate",
            "-of", "json", str(source)], env=environment, text=True))["streams"][0]
        if probe["pix_fmt"] not in ("yuv420p", "yuv420p10le"):
            raise RuntimeError(f"Unsupported test pixel format: {probe}")
        pixel_format = "p010le" if probe["pix_fmt"] == "yuv420p10le" else "nv12"
        case = dict(input=source.name, inputSha256=hashlib.sha256(source.read_bytes()).hexdigest(),
                    stream=probe, hashes={}, measurements={"hardware": [], "software": []})
        def command(mode):
            hw = ["-hwaccel", "vaapi", "-hwaccel_device", args.device,
                  "-hwaccel_output_format", "vaapi"] if mode == "hardware" else ["-hwaccel", "none"]
            return common + hw + ["-i", str(source), "-map", "0:v:0", "-an", "-sn",
                                  "-frames:v", str(args.frames)]
        for mode in ("hardware", "software"):
            output = args.output / f"{source.stem}-{mode}.framemd5"
            log = args.output / f"{source.stem}-{mode}-hash.log"
            filters = ("hwdownload," if mode == "hardware" else "") + "format=" + pixel_format
            case["hashes"][mode] = run(command(mode) + ["-vf", filters, "-f", "framemd5", str(output)],
                                       log, environment)
            if mode == "hardware" and "hardware decoder opened" not in log.read_text():
                raise RuntimeError(f"Hardware decoder was not confirmed: {log}")
        hw_rows = frame_rows(args.output / f"{source.stem}-hardware.framemd5")
        sw_rows = frame_rows(args.output / f"{source.stem}-software.framemd5")
        if len(hw_rows) != args.frames or hw_rows != sw_rows:
            raise RuntimeError(f"Frame count, timestamps or pixels differ: {source}")
        case["identicalFrames"] = len(hw_rows)
        # Alternate order so the same mode is not always measured first.
        for iteration in range(args.repeats):
            order = ("hardware", "software") if iteration % 2 == 0 else ("software", "hardware")
            for mode in order:
                log = args.output / f"{source.stem}-{mode}-null-{iteration}.log"
                measured = run(command(mode) + ["-f", "null", "-"], log, environment)
                if measured["frames"] != args.frames:
                    raise RuntimeError(f"Incomplete benchmark: {log}")
                case["measurements"][mode].append(measured)
        case["median"] = {mode: {metric: statistics.median(m[metric] for m in measurements)
                                  for metric in ("fps", "wallSeconds", "cpuSeconds")}
                          for mode, measurements in case["measurements"].items()}
        report["cases"].append(case)
        (args.output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({"input": source.name, "identicalFrames": len(hw_rows),
                          "median": case["median"]}), flush=True)
    print(f"PASS: {len(report['cases'])} streams, {args.frames} exact frames each")


if __name__ == "__main__":
    main()
