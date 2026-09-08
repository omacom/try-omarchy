# Native hardware video

For ten-bit HDR presentation in Vivaldi and mpv, see [native HDR](native-hdr.md).

The guest's `omarchy` VA-API driver sends compressed video to a supervised Swift
helper on the Mac. VideoToolbox sessions require hardware decoding and must
confirm `UsingHardwareAcceleratedVideoDecoder=true` before they are exposed to
the guest. Unsupported hardware or streams fall back through the application's
normal software decoder.

## Applications

| Application | Verified path | Launch |
| --- | --- | --- |
| mpv | HEVC Main/Main10, AV1 Main, VP9 profiles 0/2 | `mpv video.mp4` |
| Firefox | HEVC Main10 with its RDD sandbox enabled | `firefox`, or **Firefox with hardware video** |
| Vivaldi | VP9 4K YouTube | Install Vivaldi from Omarchy's browser menu |

The reviewed ARM Chromium package was built without VA-API support. Adding
Chromium command-line switches cannot enable code absent from its binary.
Vivaldi's launcher advertises the VP9 path verified with its own decoder.
HEVC and AV1 in mpv use the private FFmpeg build, which preserves compressed
headers that a remote decoder needs. The patch is conditional on the Omarchy
VA-API vendor and leaves other VA-API drivers' submissions unchanged.

Firefox opens two restricted decoder connections in its RDD process before
installing that process's sandbox. The supplied default preferences disable
the forkserver so the RDD constructor runs. Seccomp and the RDD sandbox remain
enabled. More than two concurrent RDD decoder connections can fall back to
software. The `Firefox with hardware video` desktop entry uses this launcher;
Arch's separate desktop entry can launch Firefox directly without it.

Firefox's slow-frame software fallback is disabled for this VM. Guest/host
scheduling can make individual frames late despite a low average decode time;
switching decoders midstream can otherwise fail HEVC playback. Unsupported
codecs and failed hardware initialization still take the software path.

The launchers set library paths only for their own processes. They do not
replace Arch's FFmpeg libraries or alter `ld.so.conf`. The mpv wrapper checks
the FFmpeg ABI; after an incompatible Arch update it uses the system stack
until the matching native-video package is available. Explicit mpv options
supplied by the user take precedence over the wrapper's defaults.

## Transport and lifetime

Compressed messages use `dev.tryomarchy.video`. For exported VA surfaces, the
host passes the decoder's IOSurface to QEMU through a private Mach capability.
QEMU imports its two planes through ANGLE and copies them on the GPU into the
guest's existing VirGL textures. Neither the guest nor the helper resolves an
arbitrary global IOSurface ID. The helper's Unix channel and Mach service are
private to that QEMU instance.

The GPU copies are flushed before acknowledging a frame. QEMU retains both the
IOSurface capability and imported textures until a GL fence signals completion,
without blocking the main loop. At most 32 imports may be pending; additional
frames use the memory path. A renderer reset cannot reuse stale GL names: any
imports belonging to the previous context stay bounded and retained until exit.

The memory path uses a dedicated 512 MiB PCI aperture created by QEMU, never VM
RAM or a shared user directory. The root guest broker copies each client's
frames into its own sealed, read-only-exported 64 MiB buffer. Only the guest
`video` group can connect. Eight broker connections are available; retaining a
descriptor after disconnect cannot expose a subsequent client's buffer.

Every frame must be released before its slot is reused. The broker completes
the host transaction even when a player exits during delivery. Message lengths,
dimensions and frame offsets are bounded; stalled partial messages and writes
time out. The helper exits with QEMU, the launcher supervises failures, and
QEMU plus launcher cleanup unlink the private aperture on shutdown.

The VA driver updates exported GPU buffers when a surface is reused. Derived
or copied CPU images retain the same pixels, including after direct GPU uploads.
NV12 and P010 integration tests verify these properties on the actual virtio
GPU. CPU readback after a host GPU copy explicitly synchronizes the VirGL
resource, since the guest's Mesa cache cannot observe the host's texture write.

## Build and verification

`guest/scripts/register-native-video.sh` builds against the staged guest's
headers and libraries after the reviewed Hyprland compiler setup. It verifies
the FFmpeg source and patch hashes from `guest/spec.json`, installs a local
`try-omarchy-native-video` package, and records source and binary hashes in
`/usr/share/try-omarchy/native-video.json`. The package joins the guest's local
Pacman repository. Its corresponding source is included with the libraries.

Run the normal repository checks with `make test`. The following additional
integration tests require Linux and, where indicated, the running VM:

```sh
c++ -std=c++17 -O2 -pthread tests/native-video-transport.cpp -o /tmp/video-transport
/tmp/video-transport
c++ -std=c++17 -O2 -pthread tests/native-video-surface.cpp \
  $(pkg-config --cflags --libs libva gbm libdrm) -o /tmp/video-surface
/tmp/video-surface
c++ -std=c++17 -O2 tests/native-video-firefox-pool.cpp -o /tmp/video-pool
LD_PRELOAD=/usr/local/lib/omarchy-video/firefox-video-bootstrap.so \
  /tmp/video-pool -contentproc rdd
c++ -std=c++17 -O2 -pthread tests/native-video-gpu.cpp \
  $(pkg-config --cflags --libs libva gbm libdrm libavformat libavcodec) \
  -o /tmp/video-gpu
/tmp/video-gpu hevc-main10.mp4
/tmp/video-gpu av1-main10.mp4
```

`pacman -Qkk try-omarchy-native-video` verifies the installed package.
`systemctl status omarchy-video-broker` checks the running service. For a player
diagnostic, `OMARCHY_VIDEO_LOG=1 mpv video.mp4` reports the codec and hardware
session; mpv must also report `Using hardware decoding (vaapi)`.

For FFmpeg commands, enable the same process-scoped environment as the player:

```sh
. /usr/local/lib/omarchy-video/environment.sh
omarchy_video_environment
omarchy_video_private_ffmpeg /usr/bin/ffmpeg
ffmpeg -hwaccel vaapi -hwaccel_device /dev/dri/renderD128 \
  -hwaccel_output_format vaapi -i video.mp4 -an -f null -
```

To reproduce the pixel and decode-throughput comparison inside the VM:

```sh
python3 tests/native-video-ffmpeg.py --output ffmpeg-results \
  --frames 120 --repeats 3 hevc-main.mp4 hevc-main10.mp4 av1-main10.mp4 vp9.webm
```

The harness compares decoded pixels, timestamps and frame counts after
`hwdownload` into NV12/P010, then measures decode-only runs separately. It
requires explicit hardware initialization, checks all requested frames, and
alternates hardware/software order across three benchmark repetitions.

On 2026-09-08, using the built runtime and a regular guest user on the M5 Pro
with 18 vCPUs and 12 GiB RAM, all 480 frames across these four streams matched
software decoding exactly. The following are median decode-only measurements:

| Stream | Hardware FPS | Software FPS | Hardware guest CPU seconds | Software guest CPU seconds |
| --- | ---: | ---: | ---: | ---: |
| HEVC 1920×1080, 8-bit | 107.91 | 189.27 | 0.157 | 2.253 |
| HEVC 3840×2160, 10-bit | 56.68 | 43.89 | 0.794 | 14.318 |
| AV1 3840×2160, 10-bit | 115.16 | 17.34 | 0.403 | 103.364 |
| VP9 3840×2160, 8-bit | 76.53 | 118.23 | 0.327 | 3.816 |

CPU time is the FFmpeg process's user plus system time in the guest; it excludes
the host decoder/helper and is not a whole-system energy measurement. Hardware
decoding reduces guest CPU work in these cases but is not always faster in wall
time. Null-output throughput excludes CPU readback and presentation; the
playback measurements below establish the separate end-to-end result.

## Playback verification

On the M5 Pro test machine, 4K/10-bit HEVC and the downloaded AV1 YouTube sample
matched software decoding frame for frame. VP9 comparison also passed. These
pixel hashes establish correctness, not playback throughput.

On 2026-09-08, the installed application and the upgraded existing user disk
passed these tests on an M5 Pro with 18 vCPUs and 12 GiB guest RAM. The VM and
the tested application were visible in the foreground, with the video shown
fullscreen. Resolutions below describe the source video; the desktop scaled
the image to the Mac's display.

| Application and stream | Measured playback | Dropped frames |
| --- | --- | --- |
| Vivaldi, [LG YouTube video](https://www.youtube.com/watch?v=njX2bu-_Vw4), VP9 3840×2160 at 59.94 FPS | Entire 126.56-second clip; 125.706 media seconds in 125.703 wall seconds during measurement | 0 of 7,529 frames in the measurement interval |
| mpv, the downloaded AV1 10-bit version of the same video | Entire 126.54-second clip at normal speed, `hwdec-current=vaapi` | 1 presentation drop; 0 decoder drops |
| mpv, HEVC 3840×2160 10-bit at 30 FPS | 58.87 seconds, `hwdec-current=vaapi` | 0 presentation or decoder drops |
| Firefox, HEVC 3840×2160 10-bit at 30 FPS | Entire 64-second clip in 64.008 wall seconds | 2 of 1,920 frames |

YouTube stayed at 2160p60 throughout the measurement, with no waiting, stalled,
error or premature pause events. Its subsequent autoplay transition is excluded
from the result. Firefox completed without a playback error; its RDD process
loaded the packaged VA driver and private FFmpeg with `NoNewPrivs=1` and
`Seccomp=2`. A network `stalled` event occurred while the local clip was already
buffered; presentation continued, with a maximum frame callback gap of 81 ms.
The broker stayed active with zero restarts throughout the main VM tests.

Background and occluded-window runs can be throttled by the desktop and must
not be used to establish foreground playback performance. Decode-only throughput
or playback that slows the media clock likewise does not prove display cadence.
These measurements establish 4K60 playback for this machine and tested streams;
other Macs and streams need their own playback measurements.

## Audio continuity

The launcher sets SDL's backend timer to 1 ms (`timer-period=1000`). With the
default 10 ms period, host scheduling delays can fill HDA's 8 KiB output ring
(42.7 ms of stereo 48 kHz S16 audio). QEMU's HDA output callback then discards
the entire ring. This produces phase jumps and missing audio even when the
guest PipeWire graph reports zero xruns. The existing guest quantum stays at
4096; increasing it further does not address this separate host buffer.

The change was checked on 2026-09-08 with the same runtime, guest, Mac speaker
route, and a 45-second 997 Hz stereo tone while Vivaldi played the 4K60 YouTube
sample muted. Both QEMU's output capture and an SDL callback capture were
analyzed before and after the timer change:

| Backend timer | Discontinuities per channel | Captured tone duration after SDL |
| --- | ---: | ---: |
| Default 10 ms | 37 | 43.3787 seconds |
| 1 ms | 0 | 45.0000 seconds |

The SDL capture includes the actual buffers supplied to the host audio backend,
including any inserted silence. It does not measure the physical speaker or
Bluetooth transport. One-millisecond scheduling increases requested timer
wakeups while audio is active; it cannot guarantee continuity during arbitrary
host stalls, suspend, or output-device changes.

To reproduce the deterministic tone check, generate and play it in the guest:

```sh
ffmpeg -f lavfi -i sine=frequency=997:sample_rate=48000:duration=45 \
  -ac 2 tone.wav
pw-play tone.wav
```

Start a capture before playback with QEMU's human monitor command
`wavcapture /absolute/path/capture.wav omarchy-audio 48000 16 2`, then close it
with `stopcapture 0` after playback. Analyze the host WAV with:

```sh
python3 tests/audio-continuity.py /absolute/path/capture.wav --duration 45
```

The test checks both channels using a sine recurrence, detects phase jumps and
inserted silence, and requires the complete source duration within 10 ms.

The September 8 playback tests used an upgraded existing guest. A subsequent
clean-install check reassembled an unprovisioned, verified factory base with
the current native overlay and verified native-video, HDR and Hyprland packages,
then finalized and repacked it with the project scripts. First boot on a new
user disk reached the graphical desktop; no prior user state was imported.
This verifies the assembled factory image and clean setup, not a complete
from-source container build: the latter stopped because pinned Rust
`1:1.98.0-1` was no longer available from the current Arch ARM repository.
The Rust pin was retained and the verified existing ttfx package was reused.
