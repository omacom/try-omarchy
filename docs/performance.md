# Performance profiling

CPU instructions execute through HVF on the Apple Silicon CPU. Graphics take a
longer path: guest Mesa → VirGL → host OpenGL ES/ANGLE → Metal → Cocoa. Accelerated
graphics therefore still have command translation, synchronization, upload, and
presentation costs. See [architecture](architecture.md) and QEMU's
[virtio-gpu documentation](https://www.qemu.org/docs/master/system/devices/virtio/virtio-gpu.html).

## Reproducible resource measurements

`scripts/profile-process.py` reads interval CPU counters and memory accounting on
macOS and Linux. It does not launch, stop, configure, or modify a VM. Specify the
actual QEMU PID, rather than the launcher PID:

```sh
python3 scripts/profile-process.py --pid QEMU_PID --seconds 60 --output dist/profile.json
```

When sampling QEMU, add `--qmp /path/to/private/qmp.sock`. The read-only QMP guard
checks the run state throughout the sample and rejects stops, resets, suspension,
shutdown, guest panic, and block-I/O errors. An invalid sample does not overwrite
an existing output file. A VM paused because its host disk is full can consume
almost no CPU; that must not be reported as healthy desktop idle.

Record host free disk space as well as memory. Leave room for writable snapshots,
shader caches, build intermediates, and other Mac applications. Prefer APFS clones
of disposable factory images over independent copies when setting up repeated
tests. Never remove personal VM disks to make space for a benchmark.

Repeat `--pid` to include integration helpers. CPU usage is summed across the
selected processes; memory remains separate per process to avoid silently adding
shared memory. The sampler checks process start identity and fails if a PID exits,
becomes inaccessible, or is reused.

- `cpu_one_core_percent`: 100% means one logical CPU fully occupied.
- `cpu_host_capacity_percent`: that value divided by the host's logical CPU count.
  QEMU at 10% of one core on a ten-core Mac occupies approximately 1% of total
  CPU capacity. This does not account for different performance/efficiency cores.
- `system_cpu_busy_percent`: all system CPU activity, including other applications
  and kernel work. Background activity cannot be attributed to QEMU.
- macOS `physical_footprint_mib`: charged memory, including compressed memory.
  RSS alone can substantially understate the VM's memory cost under host pressure.
- Linux `proportional_resident_mib` and `proportional_swap_mib`: PSS and swap PSS
  when permitted. These are different accounting measures from macOS footprint.

Apple Silicon's `proc_pid_rusage` CPU times are Mach ticks, not nanoseconds. The
sampler converts using `mach_timebase_info`. A missing permission or unsupported
accounting source is an error, never a zero-usage result.

For native Omarchy, copy the script to that machine and sample its compositor:

```sh
python3 profile-process.py --pid "$(pgrep -x Hyprland)" --seconds 60 --output /tmp/native-profile.json
omarchy dev benchmark cli --repeat=10
```

The first command also records whole-system CPU utilization, which is the useful
metric for a native OS idle comparison. Include the shell's PID to inspect its
individual memory cost. The upstream [CLI benchmark](https://github.com/basecamp/omarchy/blob/c668141e9c42b13c80c9ca4ea108e11708c5e8a5/bin/omarchy-dev-benchmark-cli)
measures common command response times; it does not measure desktop graphics.
Record CPU/GPU models, core count, OS/package versions,
power profile, resolution, scale, refresh rate, open applications, and whether
the screen is displaying the desktop, lock, or animated screensaver.

Measure settled desktop idle separately from boot, app startup, screensaver,
video, builds, and camera use. Compare equal work and include frame-time tails,
CPU seconds per workload, and memory after applications close. Record concurrent
host activity; a quiet baseline and a loaded-host run answer different questions.
Offscreen synchronous graphics throughput does not establish on-screen FPS or
input latency. Do not infer hardware video decoding from an accelerated desktop.

## 2026-10-01 investigation

Host: M2 Pro, ten cores (six performance/four efficiency), 16 GiB, macOS 27.0.1.
Source: `prepare-0.5.0`, initially `3cfee41`; optimization checkpoint `0bd5348`, Bash compatibility fix `3e24c17`.
Guest: current factory pinned to Omarchy release 4.0.4 (source-reported
4.0.0.alpha), Linux 7.2.8, Hyprland 0.56.2, Aquamarine 0.15.1.

The desktop tests used disposable snapshots of the newly provisioned factory QA
disk, not the personal VM. Cocoa used an 840×474 backing-pixel window, scale 2,
with a roughly 120 Hz EDID. Fullscreen and input grabbing were disabled while the
Mac was in use. These results do **not** certify fullscreen Retina frame pacing.
QEMU's CPU/memory figures below exclude the separate native integration helpers
and additional WindowServer/GPU costs.

| Settled desktop, 30 seconds | QEMU CPU, one core | QEMU CPU, ten-core capacity | macOS charged footprint | Guest RAM used¹ |
| --- | ---: | ---: | ---: | ---: |
| Original renderer, 4 CPUs / 4 GiB | 9.56% | 0.96% | 2872 MiB | 729 MiB |
| Optimized renderer, 4 CPUs / 4 GiB | 9.82% | 0.98% | 2792 MiB | 729 MiB |
| Optimized renderer, default 8 CPUs / 8 GiB | 10.00% | 1.00% | 2842 MiB | 790 MiB |

¹ `MemTotal - MemAvailable`, an estimate rather than the sum of application RSS.
The default-capacity guest also retained about 849 MiB of buffers/file cache and
had about 7.0 GiB available. Selected capacity is not physical host residency.
After repeated browser/graphics workloads the four-GiB VM's charged footprint
reached roughly 3.5 GiB; idle and workload memory should not be conflated.

The original renderer's small-window animated screensaver used about 33% of one
host core (3.3% of total capacity). It is an active rendering workload. Earlier
QA samples near 170% of one core had no controlled workload attribution and are
not evidence of idle CPU usage.

The user's approximately 2% native idle figure is a reference, not a measured
hardware-matched baseline. Its denominator and hardware are unknown. Neither
these results nor online reports establish a VM/native performance ratio.
The official manual's [native Mac performance example](https://learn.omacom.io/2/the-omarchy-manual/97/mac-support)
reports a gain on a 2019 Intel MacBook Pro after installing Omarchy. That is
different hardware and a different comparison; it does not measure this ARM64 VM.

A short host stack sample showed the vCPUs predominantly waiting for interrupts,
with the main loop, ANGLE workers, and Cocoa event loop predominantly sleeping.
It did not reveal a persistent busy loop. This is a qualitative stack check,
not a statistical attribution of CPU time or a GPU utilization measurement.

### Change and observed benefit

VirGL was built with Meson's `debug` setting, which selects `-O0`. It now uses
`debugoptimized` (`-O2`) with `b_ndebug=false`; graphics functionality, assertions,
diagnostics, source pins, and compatibility patches are retained. All 90 captured
VirGL compile commands used `-O2` without `-DNDEBUG`. Meson's
[build-type documentation](https://mesonbuild.com/Builtin-options.html#details-for-buildtype)
describes these options. `OMARCHY_RUNTIME_BUILD_JOBS=2` also bounds compilation
while other host applications are in use.

Alternating original/optimized runs exercised small command-heavy draws,
1280×720 fill, and 1280×720 texture uploads through the actual guest VirGL
renderer. Every run validated the returned pixel values. Warm runs overlapped:
command-heavy median frames were about 2.9 ms originally and 2.8–2.9 ms optimized;
fill about 1.2–1.5 ms and 1.4–1.7 ms; upload about 2.2–3.0 ms and 2.1–2.4 ms.
Other runs took 25–34 ms per frame under contention. The removed unoptimized path
is a concrete improvement to the build; these measurements do not establish a
reliable percentage improvement in end-to-end responsiveness.

Factory `foot` terminal startup mapped a window in 78–254 ms before and 145–184 ms
after; Chromium with a private blank profile took 2.40–2.98 s before and
1.94–3.15 s after. These are small samples of window availability, not first
interactive frame or a controlled native comparison. Actual Wayland output was
captured and inspected after the change.

A deterministic 50-million-iteration integer workload returned identical results
in native macOS and Linux/HVF. The last three pairs took 0.099–0.103 s on macOS and
0.102–0.108 s in HVF. Earlier VM runs took 0.179 and 0.766 s. Different compilers,
host scheduling, and core placement prevent treating this as an exact overhead
measurement; it demonstrates that CPU-bound work can execute close to native
speed, with substantial contention outliers.

### Memory and reliability

The rebuilt runtime's existing disposable reclamation test verified three
768-MiB allocation/reuse cycles with a live sentinel. It returned 740.3, 754.2,
and 732.3 MiB of charged footprint. A temporary reduction of Linux's free-page
reporting order from 9 to 7 did not produce a useful saving in the desktop trial;
the default was restored and no guest memory policy was changed.

Free-page reporting does not tell Linux to release its file cache when macOS is
under pressure. Automatically dropping caches would sacrifice useful work and
increase later I/O. A future pressure-aware balloon controller needs a guest RAM
floor, hysteresis, allocation-latency and swap-pressure measurements, failure
recovery, and long-run validation before it becomes a daily-use default.

Settled default-capacity checks found no failed system or user services. Desktop
VMs shut down orderly between runs. No personal disk, resource preference,
clipboard, camera, or microphone content was used for these benchmarks.

### Short repeated desktop check

The final rebuilt runtime completed ten cycles of opening a private blank-profile
Chromium window and `foot`, validating 1920×1080 draw/upload pixels, and closing
the applications. Between cycles, guest estimated RAM used ranged from 791 to
822 MiB and ended at 807 MiB; no guest swap was used and no system/user services
failed. Warm synchronous draw medians were 1.45–1.87 ms and uploads 2.96–4.22 ms.

A five-minute host sample overlapping this repetition and diagnostic/CLI checks
averaged 19.67% of one core (1.97% of ten-core capacity), with a median interval of
9.69% of one core. Whole-system busy CPU was 28.34%, including other Mac activity.
Charged QEMU memory ranged from 3773 to 4009 MiB and ended at 3960 MiB. These are
mixed-workload figures, not another idle comparison or proof of an all-day leak
plateau. They show why launch/working-session costs should accompany idle figures.

The upstream CLI benchmark completed ten repetitions of each case. Plain/help
commands averaged 17.9/24.1 ms; `commands` averaged 783 ms, JSON enumeration
367/225 ms, and the remaining help/theme cases 5.4–184 ms. No native counterpart
was measured. The initial synchronous invocation exceeded the QA agent's
eight-second command limit; an asynchronous run completed with exit status zero.

An attempted `egl-headless` launch exited before boot: this macOS runtime does
not support that display backend. The repetition used the same small Cocoa
window with input grabbing disabled. Final actual Wayland output was inspected.
The guest error journal contained a login-keyring unlock message; no workload
crash, OOM, or I/O errors appeared in that journal. That is a short smoke check,
not sleep/wake, physical audio, or long-session certification.

### Video acceleration

FFmpeg lists VA-API among its compiled methods, and initializing the guest's
`/dev/dri/renderD128` VA-API device succeeds. Neither proves codec acceleration.
Querying the actual VA-API 1.24 profiles returned only `VAProfileNone (-1)` with
`VAEntrypointVideoProc (10)`, with no codec decode profiles. Those constants are
defined in the [primary libva API](https://github.com/intel/libva/blob/master/va/va.h).
`vainfo` was not installed; the check called libva's profile/entrypoint APIs
directly instead. The current VirGL build also explicitly has `video=false`.

Hardware video decoding is consequently unavailable through this VA-API path.
Adding reliable host video acceleration requires a supported guest/host bridge;
enabling a browser flag or declaring graphics accelerated does not supply one.
Video playback CPU, dropped frames, and battery cost need separate measurements.

### Verification and remaining work

- `OMARCHY_RUNTIME_BUILD_JOBS=2 nice -n 10 make runtime`: passed; shader/blend
  regressions, libslirp tests, compatibility audits, and runtime validation passed.
  An intermediate Bash fix failed because `env` cannot invoke a shell function;
  the final fix keeps direct Ninja invocation with guarded array expansion.
- `nice -n 10 make app`: passed before concurrent guest-upgrade edits began;
  strict app signature and all 22 Mach-O deployment targets validated.
- `OMARCHY_RUNTIME_BUILD_JOBS=2 OMARCHY_GUEST_BUILD_JOBS=2 nice -n 10 make app`:
  a later current-workspace assembly rebuilt and packed the guest, including a
  successful filesystem check, but the build cache rejected the result because
  unrelated guest migration inputs changed during compilation. No successful
  cache state was published for that attempt.
- `python3 macos/Tests/hvf-memory-reclaim-smoke.py --qemu macos/.build/qemu-gpu-runtime/bin/qemu-system-aarch64 --guest-dir dist/guest`: passed.
- `nice -n 10 make test TEST_JOBS=2`: failed with three settings-install tests
  during concurrent changes to the unrelated guest-upgrade flow. Those edits
  were preserved. Later workspace reruns passed, including the final Bash fix:
  383 Swift tests in 83 suites, 334 guest tests, runtime/shell contracts, and
  16 disk-resize tests.
- `nice -n 10 make -C dist/performance-2026-10-01/verification-source test TEST_JOBS=2`
  against an isolated `git archive 0bd5348`: passed, including 378 Swift tests,
  310 guest tests, runtime/shell contracts, and 16 disk-resize tests.
- Sampler CPU counters agreed with real `getrusage` on macOS and Linux; malformed
  durations/PIDs and invalid compilation budgets were rejected. A real Linux
  container and macOS process exercised whole-system CPU sampling. Apple Bash
  3.2 checks verified unset, empty, and explicit compilation budgets, preserving
  argument boundaries for paths containing spaces. `bash -n` and
  `git diff --check` passed.
- `python3 tests/test-profile-process.py`: passed all four tests, including
  stopped/error states, transient QMP events, malformed replies, and preserving
  earlier measurements after an invalid sample. Socket binding was denied in the
  sandbox; the same tests passed outside it. The updated sampler also ran against
  actual Linux counters and a real QEMU QMP socket.

Raw logs, workload sources, JSON measurements, and guest captures are local under
`dist/performance-2026-10-01/` and are deliberately not committed.

Priorities for further daily-use work are fullscreen 60/120-Hz frame-time and
input-latency measurements, graphics upload/synchronization costs, browser video
decoding, audio continuity under rendering load, and memory behavior during a
long browser/editor/build session alongside Mac applications. Keep existing
animations, display resolution, refresh support, checksums, durable I/O, and
recovery policies while investigating these costs. Nested virtualization on
newer chips, physical sleep/wake, long-session leak behavior, and a native
Omarchy hardware comparison were not verified by this run.
