# Native hardware video

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

The local upgrade used for these tests retained the application's existing
factory image. **Reset Omarchy restores that earlier guest baseline.** A new
factory image built from this branch includes the native-video package through
the guest build integration described above.
