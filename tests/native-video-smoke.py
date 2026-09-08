#!/usr/bin/env python3
"""Prepare a reproducible HEVC packet corpus, or decode it inside a Linux guest.

prepare INPUT.mp4 OUTPUT.tovd: uses ffprobe without decoding the input.
decode INPUT.tovd OUTPUT.json [PORT]: exercises the real virtio/VideoToolbox path.
The report hashes every complete decoded frame and includes transport time.
"""

import hashlib
import json
import os
import struct
import subprocess
import sys
import time

HEADER = struct.Struct("<4sHHIIQIIII")
MAGIC = b"TOVD"
MAX_PAYLOAD = 64 * 1024 * 1024


def unhex(data):
    return bytes.fromhex("".join(line.split(": ", 1)[1].split("  ", 1)[0]
                                 for line in data.splitlines() if ": " in line))


def message(op, token=0, payload=b""):
    return HEADER.pack(MAGIC, 1, op, 1, len(payload), token & ((1 << 64) - 1), 0, 0, 0, 0) + payload


def prepare(source, target):
    result = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_streams",
        "-show_packets", "-show_data", "-of", "json", source,
    ]))
    stream = result["streams"][0]
    if stream["codec_name"] != "hevc":
        raise ValueError("test corpus must contain HEVC")
    config = unhex(stream["extradata"])
    with open(target, "wb") as output:
        output.write(message(1, payload=config))
        for packet in result["packets"]:
            output.write(message(2, int(packet["pts"]), unhex(packet["data"])))
        output.write(message(3))
        output.write(message(4))
    print(json.dumps({"packets": len(result["packets"]), "width": stream["width"],
                      "height": stream["height"], "time_base": stream["time_base"]}))


def exact(read, count):
    parts = []
    remaining = count
    while remaining:
        part = read(remaining)
        if not part:
            raise EOFError("video channel closed during response")
        parts.append(part)
        remaining -= len(part)
    return b"".join(parts)


def receive(read):
    header = exact(read, HEADER.size)
    fields = HEADER.unpack(header)
    if fields[:2] != (MAGIC, 1) or fields[4] > MAX_PAYLOAD or fields[-1] != 0:
        raise ValueError("invalid video response")
    return fields, exact(read, fields[4])


def decode(source, target, port):
    descriptor = os.open(port, os.O_RDWR | os.O_CLOEXEC)
    frames = []
    opened = None
    packets = 0
    start = time.monotonic()
    try:
        with open(source, "rb") as corpus:
            while True:
                request = corpus.read(HEADER.size)
                if not request:
                    break
                fields = HEADER.unpack(request)
                payload = exact(corpus.read, fields[4])
                data = request + payload
                offset = 0
                while offset < len(data):
                    offset += os.write(descriptor, data[offset:])
                while True:
                    response, pixels = receive(lambda n: os.read(descriptor, n))
                    op = response[2]
                    if op == 0xffff:
                        raise RuntimeError(pixels.decode(errors="replace"))
                    if op == 0x8100:
                        width, height, fmt = response[6:9]
                        expected = width * height * 3 // 2 * (2 if fmt == 2 else 1)
                        if len(pixels) != expected:
                            raise ValueError("invalid decoded frame length")
                        frames.append({"token": response[5], "sha256": hashlib.sha256(pixels).hexdigest(),
                                       "bytes": len(pixels), "format": "p010le" if fmt == 2 else "nv12"})
                    elif op == fields[2] | 0x8000:
                        if op == 0x8001:
                            opened = {"width": response[6], "height": response[7],
                                      "hardware": bool(response[8] & 0x100)}
                        break
                    else:
                        raise ValueError("unexpected response operation")
                packets += fields[2] == 2
    finally:
        os.close(descriptor)
    elapsed = time.monotonic() - start
    if not opened or not opened["hardware"] or len(frames) != packets:
        raise RuntimeError("not every packet produced a hardware-decoded frame")
    report = {"opened": opened, "packets": packets, "frames": frames,
              "elapsed_seconds": elapsed, "fps": len(frames) / elapsed}
    with open(target, "w") as output:
        json.dump(report, output, indent=2)
    print(json.dumps({**opened, "frames": len(frames), "elapsed_seconds": elapsed,
                      "fps": len(frames) / elapsed}))


if __name__ == "__main__":
    if sys.argv[1] == "prepare":
        prepare(*sys.argv[2:])
    elif sys.argv[1] == "decode":
        decode(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4
               else "/dev/virtio-ports/dev.tryomarchy.video")
    else:
        raise SystemExit("usage: native-video-smoke.py prepare|decode INPUT OUTPUT [PORT]")
