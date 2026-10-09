# Native OpenGL HDR prototype

This opt-in review prototype extends upstream commit `61d86ed1e691de44f3e50fdef4c78500abcfbf57`.
It keeps the native Apple OpenGL VirGL renderer (`cocoa,gl=on`) and the existing
`QemuCGLLayer` display cadence. It does not use the previous ANGLE/EGL HDR presenter.

The private virtio HDR feature, command validation, resource-matched metadata
latching, and BT.2020/PQ EDID remain compatible with the previously patched guest.
Unmodified guest drivers do not negotiate the private feature and retain SDR.
The launcher enables HDR only when `OMARCHY_NATIVE_OPENGL_HDR=1` and its bundled
runtime exposes `x-omarchy-hdr`. Ordinary launches keep the SDR default. For a
development app, launch its executable from a terminal with that environment
variable; GUI launches do not inherit arbitrary shell variables. The built
Cocoa runtime can also be exercised directly with the smoke test below.

The final native OpenGL pass writes linear BT.2020 into the Cocoa layer's
16-bit floating-point backing buffer. The layer opts into macOS EDR and uses
`kCGColorSpaceExtendedLinearITUR_2020`. PQ is converted to nits and divided by
the host SDR-white hint (100 nits if the optional preset query is unavailable).
For SDR scanouts, the shader linearizes sRGB and converts its primaries to
BT.2020; SDR white remains 1.0. Text consoles and boot surfaces always use this
SDR path. Framebuffer precision and shader initialization failures stop startup
instead of silently advertising HDR through an SDR buffer.

This prototype relies on WindowServer's display color matching and EDR clipping.
It does not provide the previous Metal layer's CAEDRMetadata tone mapper, and
content brighter than available display headroom may clip. The private HDR
metadata protocol supports SDR and HDR10/PQ, not HLG or Dolby Vision.
The OpenGL APIs are deprecated by Apple but remain available on the supported
macOS 15+ runtime. The SDR-white preset query is an optional private API retained
from the earlier patch; it never changes host display settings.

## Verification

Run the actual shader and a real shared-context Cocoa layer on a Mac with GPU
and WindowServer access:

```sh
python3 tests/native-opengl-hdr.py
```

The test checks PQ levels, SDR white/gamma, sRGB-to-BT.2020 red, 10-bit input,
texture orientation, shared CGL texture/program objects, floating-point backing,
and values above SDR white. It reports a small final-pass GPU benchmark at
3456x2160 and the screen's reported EDR headroom. Pixel readback and headroom
reports do not measure physical display luminance or prove browser HDR selection.

Build and run the existing suite:

```sh
make runtime
make test
```

With a runtime staged, the disposable startup test checks HDR and ordinary SDR
Cocoa startup plus clean QMP exit without attaching a VM disk:

```sh
python3 tests/native-opengl-hdr-smoke.py
```

## Persistent-guest validation and remaining gates

An existing patched persistent guest was tested on Apple M3 Max with Linux
7.2.5, Hyprland 0.56.1, Aquamarine 0.14.0, and Mesa 26.2.3. Vivaldi retained
hardware-accelerated canvas, compositing, rasterization and WebGL with GaneshGL
and VirGL/Apple M3 Max. HDR media queries returned true; the monitor reported
XRGB2101010 at 120 Hz. YouTube selected 3840x2160@60 with SMPTE 2084/PQ and
BT.2020 instead of the earlier BT.709 stream. This verifies HDR stream delivery,
not the physical panel luminance or decoder hardware use.

Two independent white-level mismatches were corrected in that guest:

- Custom display helpers forced 105 nits despite an EDID hint of 600 nits.
  Respecting the hint corrected the ordinary desktop and terminal appearance.
- Wayland clients received a fixed 203-nit reference despite the compositor's
  600-nit policy. The accompanying Hyprland patch changed the live protocol
  reference to 600 (peak 993 and PQ retained), and Vivaldi/1Password light
  backgrounds recovered their normal appearance after restarting the session.

See [guest compatibility patches](../guest/hdr/README.md). This draft does not
register those patches in the factory builder, update package pins, or replace
existing user configuration. The tested guest package differs from upstream's
current factory stack; a fresh factory build/boot is still required.

The final-pass GPU test measured approximately 0.50 ms for an SDR copy and
0.67 ms for the PQ/FP16 pass at 3456x2160 on the test Mac. These are small shader
microbenchmarks, not end-to-end VM frame timing. One YouTube capture showed 42
drops out of 2232 frames; no controlled steady-playback comparison was run.
A 120 Hz guest mode does not prove 120 frames are presented every second.

Remaining gates include exact factory-kernel integration, the pinned factory
Hyprland build, existing-guest migration policy, real SDR/HDR transition and
sleep/wake testing, other Mac generations/external displays, clipping/tone-map
policy, physical luminance, and an end-to-end performance comparison. Apple
OpenGL is deprecated; the private virtio extension and optional private display
preset query also require maintainer review before this can become a default.
