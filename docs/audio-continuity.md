# Audio continuity under graphics load

## Problem and behavior

A delayed audio callback can leave the emulated HDA output ring full. The original
QEMU callback drops all 8192 queued bytes, resets both positions and returns
without supplying audio to the backend. That discards approximately 46 ms of
44.1 kHz stereo S16 audio (43 ms at 48 kHz).

The recovery patch keeps the queued bytes and positions, rebases the producer
clock to the current write position, and continues the existing bounded write
loop. A backend that accepts only part of the data, or none, leaves the remainder
queued. The clock rebase prevents an old elapsed-time deficit from driving a
prolonged catch-up burst. The existing bounded clock correction remains active.

The launcher also requests a 1 ms SDL audio timer and eight output buffers instead
of the defaults of 10 ms and four buffers. The timer and larger host queue reduce
exposure to scheduling gaps; neither prevents the main loop from being delayed.
The guest PipeWire quantum and existing user application configurations are not
modified.

## Regression coverage

`make test` compiles the patched HDA producer and consumer functions with
AddressSanitizer and UndefinedBehaviorSanitizer. Controlled backend writes verify
sample preservation, full/partial/zero writes, zero available capacity, ring
wraparound, large running positions, 44.1/48 kHz stereo, ordinary non-full/empty
rings, and bounded producer catch-up after a simulated ten-second stall. This
is a device-function test with a modeled backend and clock correction, not a
physical audio or end-to-end latency test.

The launcher contract test checks the exact audio argument. The normal pinned
runtime build verifies patch hashes, applies the patches to the source archive,
and checks the relocated, signed runtime.

## Manual reproduction

Use the same app build, audio output device, host volume, guest display mode,
window size, browser page, stream and application buffer throughout a comparison.
Keep the VM and host otherwise idle. Prefer a local audio fixture for a strict
comparison; streaming adds network and content variability.

1. Play audio continuously and listen for eight seconds with the browser idle.
2. Repeatedly change browser page zoom for twenty seconds. Responsive pages
   generate substantial layout and repaint work.
3. Stop zooming and listen for eight more seconds.
4. Record clicks separately for each phase; repeat without changing settings.
5. Play a clip with coincident visual flashes and beeps, first idle, then while
   zooming, and then idle again. Note a fixed offset separately from growing lag.
6. Also exercise tiled app opening/closing and ordinary video playback. These
   are additional workloads, not equivalent to the page-zoom comparison.

For automated QEMU tracing, enable `hda_audio_full_recovery` only for the capture
and restore tracing afterward. Recovery events are not audible click counts.
Guest audio-server error counters alone cannot establish clean host output.

## Development observations and limits

The recovery logic was evaluated in a custom macOS/HVF/VirGL build. Fullscreen
real-stream tests used a 4112 x 2582, approximately 120 Hz HDR guest display.
The experimental build included additional graphics patches; its results should
not be represented as a fresh measurement of the upstream-main integration.

- Preserving full HDA rings substantially improved repeated listening trials.
- With the recovery patch and 1 ms timer already present, increasing SDL output
  buffers from four to eight improved two live-stream zoom trials. The repeat
  had approximately two or three brief clicks during zooming and none before or
  afterward. The workload was manual, and a VM restart separated configurations.
- An audiovisual check with eight buffers showed slight perceived startup audio
  lag, then close synchronization during and after zooming. Absolute latency was
  not measured and there was no matched four-buffer synchronization control.
- Increasing cliamp's application buffer from 1000 to 2000 ms further reduced
  browser-triggered interruptions. App opening could still provoke stutter in
  subsequent informal testing. Later, the same recovery executable and launcher
  settings were reported to work for several days without issues in normal use.

For cliamp users, the separately tested application setting was:

```toml
buffer_ms = 2000
```

This is an opt-in application mitigation, not a system-wide default or a claim
that every player needs two seconds of buffering. The guest application buffer,
guest audio graph and host SDL queue are distinct stages. The multi-day report
covers their combined configuration and does not isolate each change's benefit.

The principal remaining tradeoffs are additional timer wakeups and potentially
higher queued-audio latency. Other machines, output devices, Bluetooth routes,
and suspend/resume require their own validation. This change does not claim to
eliminate graphics stalls or all audio interruptions.
