#!/usr/bin/env python3
"""Check a captured 16-bit PCM sine for discontinuities and missing duration.

Generate the source with FFmpeg's sine filter, play through the guest, and
capture the host output. This checks the actual audio path, not video counters.
"""

import argparse
import array
import json
import math
import sys
import wave


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture")
    parser.add_argument("--frequency", type=float, default=997)
    parser.add_argument("--duration", type=float, required=True)
    args = parser.parse_args()
    with wave.open(args.capture) as source:
        if source.getsampwidth() != 2 or source.getcomptype() != "NONE":
            parser.error("capture must be uncompressed 16-bit PCM")
        rate, channels = source.getframerate(), source.getnchannels()
        samples = array.array("h", source.readframes(source.getnframes()))
    if sys.byteorder != "little":
        samples.byteswap()
    if not 0 < args.frequency < rate / 2 or args.duration <= 0:
        parser.error("frequency must be below Nyquist and duration positive")
    results = []
    for channel in range(channels):
        values = samples[channel::channels]
        peak = max(map(abs, values), default=0)
        if peak < 100:
            raise SystemExit(f"Channel {channel} is silent or too quiet to measure")
        active = [i for i, value in enumerate(values) if abs(value) > peak * 0.02]
        start, end = active[0], active[-1]
        # A sine obeys y[n] = 2*cos(w)*y[n-1] - y[n-2]. Phase jumps,
        # inserted silence and dropped samples violate that recurrence.
        coefficient = 2 * math.cos(2 * math.pi * args.frequency / rate)
        threshold = max(20, peak * 0.05)
        groups = []
        previous = -rate
        maximum = 0.0
        for i in range(start + 2, end + 1):
            residual = abs(values[i] - coefficient * values[i - 1] + values[i - 2])
            maximum = max(maximum, residual)
            if residual > threshold:
                if i - previous > rate / 100:
                    groups.append(round((i - start) / rate, 6))
                previous = i
        duration = (end - start + 1) / rate
        results.append({"channel": channel, "durationSeconds": duration,
                        "peak": peak, "maximumResidual": maximum,
                        "discontinuities": len(groups), "timesSeconds": groups,
                        "passed": not groups and abs(duration - args.duration) < 0.01})
    print(json.dumps({"sampleRate": rate, "channels": results}, indent=2))
    return 0 if all(result["passed"] for result in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
