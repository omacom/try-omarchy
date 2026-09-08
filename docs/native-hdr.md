# Native HDR output

The native QEMU display can present HDR10/PQ video from Vivaldi's YouTube player
and local files opened with `mpv`. This extends the hardware decoder described in
[native video](native-video.md): preserving ten decoded bits alone does not make
an eight-bit SDR desktop an HDR display.

## Display path

The paired guest driver exposes ten-bit RGB scanout and the DRM `Colorspace` and
`HDR_OUTPUT_METADATA` properties. Hyprland composites into BT.2020/PQ. QEMU copies
that scanout into an RGBA16Float IOSurface and presents it through a Metal layer
with extended dynamic range enabled. The Metal shader converts PQ to linear
BT.2020, with linear 1.0 representing 100 cd/m² in the content's metadata.

ANGLE and Metal share each IOSurface. An exported Metal shared event orders their
GPU work; production presentation does not read back pixels or wait for frame
completion on the CPU. Metal drawable acquisition runs on a separate serial
queue so WindowServer backpressure cannot block QEMU's main loop. If all three
surfaces are in flight, the next refresh retries with the latest guest frame.
The presenter also holds a macOS activity token so App Nap cannot throttle
the running VM when its window loses focus. Normal system sleep remains
allowed. The pool holds three reusable surfaces. At 3840×2160 these
surfaces use approximately 190 MiB, in addition to Metal's drawable pool and the
existing guest framebuffer resources. Surface allocation is bounded to an 8K
pixel count in either display orientation.

The virtual EDID advertises PQ, BT.2020 RGB, a nominal 1000-nit peak and 400-nit
frame-average peak. CTA encodes the nominal peak as approximately 993 nits. These
are virtual display capabilities, not a measurement of the Mac's panel. macOS
system tone mapping adapts the extended-range output to the display containing
the window. Cocoa queries the active display preset's maximum SDR luminance and
passes it to the guest in an additional-text EDID descriptor (`TO-SDR:<nits>`).
The display helper uses that cap for SDR desktop white, bounded by the virtual
display's 1000-nit output. Screen and display-parameter changes update the hint
through the existing display hotplug path. PQ video retains its absolute
luminance; the presenter's 100 cd/m² linear reference and HDR metadata stay
unchanged. The brightness slider on the Mac continues to work normally.

The host query dynamically loads optional private CoreDisplay APIs to read
`PresetMaxSDRLuminance` from the selected display's active preset. It is a
capability hint, not a panel measurement. It never substitutes HDR peak
brightness, the backlight cap, an EDR ratio, or a Mac model name for an SDR
maximum. Unknown hosts, monitors without a readable preset, and malformed
values retain a 250-nit fallback. An explicit guest monitor rule still wins.
For example, the standard XDR preset may report 600 nits for SDR, while its
separate outdoor auto-brightness limit is 1000 nits and its HDR peak is 1600.

## Compatibility and application setup

The transport is a **private paired extension**, not an upstream virtio HDR
standard: feature bit 6, command `0x0400`, magic `0x544f4844`, version 1. The
command contains a 24-byte virtio header and eighteen little-endian 32-bit
fields. Metadata is associated with its scanout resource and latched at that
resource's flush. Unsupported transfers, invalid values and unknown resources
are rejected. Reset and resource destruction clear pending state.

The launcher enables `x-omarchy-hdr=on` and Cocoa `hdr=on` only when the runtime
exposes the private property. The EDID advertises HDR only after the guest
negotiates the feature and the host presenter is available. An older guest
driver therefore continues to expose its ordinary SDR display. If the HDR
presenter cannot initialize, QEMU uses its SDR presentation path.

`omarchy-native-display-sync` enables ten-bit HDR only when valid EDID extension
blocks contain both PQ/static metadata and BT.2020 RGB support. Explicit user
monitor rules keep their existing precedence. Vivaldi enables Wayland color
management in addition to its existing VP9 hardware decode flags.

The pinned Hyprland package also advertises this SDR-white level in Wayland
output and preferred-surface descriptions. Chromium composes its interface into
PQ, so leaving these descriptions at Hyprland's fixed 203-nit reference makes
the browser dim beside an unmanaged wallpaper mapped to the host's SDR maximum.
`guest/patches/hyprland/client-sdr-white.patch` updates client descriptions and
notifies existing surfaces when SDR brightness changes. The compositor's HDR
render description, PQ transfer function, mastering metadata, and tone mapping
remain unchanged. SDR and ICC outputs retain their existing descriptions.
Chromium also uses the advertised white level for its own HDR tone mapping, so
raising it can brighten video midtones while retaining HDR highlights. Keeping
the compositor's PQ interpretation unchanged does not freeze a client's rendering.

The mpv wrapper selects the private HDR runtime only for an active ten-bit
virtual HDR monitor. Its OpenGL output uses a ten-bit EGL surface and publishes
the renderer's actual target parameters through Wayland color management. The
bundled target is BT.2020/PQ. Command-line options supplied by the user still
take precedence.

The private Mesa build changes the minimum GLES version for
`EXT_texture_norm16` from 3.1 to 3.0, matching revision 6 of the Khronos extension.
This makes the existing R16/RG16 support available to mpv's P010 importer. The
private mpv patch supplies the Wayland color surface that this pinned Mesa EGL
backend does not manage. Both libraries are scoped to mpv's process; they do
not replace the system Mesa or mpv packages.

## Building and installing

`python3 tests/native-client-sdr-white.py` compiles the client-white policy from
the actual Hyprland patch and checks display values, bounds, and preservation of
the internal HDR description. Runtime validation compares the half-float PQ
scanout for a Chromium white page and an unmanaged white surface, then checks
that mpv's explicitly targeted PQ output stays unchanged when SDR white changes.
A tagged VP9/PQ browser fixture separately verifies Chromium's HDR highlights
and its adaptation of midtones to the new white level. These are digital signal
checks; measuring the physical panel luminance requires a colorimeter.

`guest/scripts/register-native-hdr.sh` runs after native video registration in
the guest builder. `guest/hdr/sources.json` pins source archives, patches, kernel
source files and additional build tools. The output package contains:

- A virtio-gpu module for **7.2.2-2-aarch64-ARCH**, under `updates/omarchy-hdr`.
- Private Mesa 26.2.1 and mpv 0.41.0 under `/usr/local/lib/omarchy-hdr`.
- Corresponding source archives, patches, build recipe and license notices.
- Source and binary hashes in `/usr/share/try-omarchy/native-hdr.json`.

Package installation, upgrade and removal regenerate module dependencies and
the initramfs. A saved VM must also receive the initramfs paired with its updated
disk; installing a module only into the root filesystem leaves an older
initramfs driver active. Preserve the VM's existing kernel, command line and
boot-kit identity, and update its initramfs checksum when performing a local
upgrade.

This is an exact-kernel module, not a DKMS build against arbitrary future
kernels. A newer guest kernel uses its stock SDR driver until a corresponding
HDR package is released. The factory-image build includes the package; an
existing VM upgraded locally does not change the app's older factory image.

## Verification

`make test` checks the guest display policy, private runtime selection, source
digests and launcher capability gating. The additional macOS integration test
executes the actual presenter code extracted from the QEMU patch:

```sh
python3 tests/native-hdr-presenter.py \
  --angle-include /path/to/angle/include \
  --epoxy-include /path/to/libepoxy/include
```

It checks SDR → HDR → SDR transitions, BT.709-to-BT.2020 primaries, image
orientation, 100/1000-nit PQ inputs and bounded nonblocking submission while
the presentation queue is stalled. GPU readback and CPU completion waits
belong only to this test. Its numerical result is not a photometer measurement.

Inside the running guest, inspect `hyprctl -j monitors` for
`XRGB2101010`, `colorManagementPreset: hdr` and SDR luminance matching the
host hint (or 250 when unavailable). `python3 tests/native-sdr-white.py` checks
the native cap conversion and reports the current host hint. For video,
verify the selected decoder, source profile, P010 pixel format and target
BT.2020/PQ separately. Browser quality labels or a ten-bit source file alone
do not prove HDR presentation.

HDR10 is the tested output contract. Dolby Vision dynamic metadata is not
transported. On the development M5 Pro, sustained checks cover visible YouTube
VP9 Profile 2 at 3840x2160/60, local AV1 10-bit at 3840x2160/60 and local HEVC
Main 10 at 3840x2160/30. The checks measure frame drops after startup and compare
media time with wall time. They are machine-specific playback results, not a
performance guarantee for every Mac or file.
