# HDR guest integration

The normal package/factory build now includes the supported HDR driver,
compositor and monitor policy. See the [build and update contract](../../docs/native-opengl-hdr-build.md)
for commands, supported versions, restart requirements and remaining limits.
The normal host launch remains SDR; use `OMARCHY_NATIVE_OPENGL_HDR=1` to opt in.

## Current implementation

- `guest/package/try-omarchy/hdr-driver/` contains checksum-inventoried Linux
  7.2.8 DRM virtio sources with the private HDR extension and GPL licensing.
  DKMS compiles against installed matching Omarchy headers; depmod selects the
  override and the normal final UKI/initramfs contains it. A new kernel source
  version requires adaptation; no foreign prebuilt kernel module is shipped.
- `guest/package/hdr-hyprland/PKGBUILD` builds the pinned 0.56.2 release source,
  retains its four packaging fixes, and applies `client-sdr-white.patch` and
  `hdr-content-peak.patch`. The companion is embedded as package-owned data
  and installed as the ordinary `hyprland` package through pacman. Source/patch
  checksums, generated artifact digest/version and dependency checks remain on.
- The normal factory and pre-login integration update share `hdr-install`.
  An unchanged companion/driver/kernel fingerprint skips DKMS/initramfs work.
  The factory defers initramfs generation to upstream's final UKI step.
- The display helper reads checksum-valid base/CTA EDID descriptors, selects
  ten-bit PQ when advertised, and honors `TO-SDR:<nits>`. Explicit per-output
  user rules still take precedence. The current host/client encoding reference
  is 100 nits, superseding the historical local 600-nit configuration.

The private interface follows the earlier work in [PR #168](https://github.com/omacom/try-omarchy/pull/168).
This draft retains native Apple OpenGL/VirGL presentation. The driver sources
are based on the Linux 7.2.8 virtio DRM directory; their complete packaged
inventory is recorded in `hdr-driver/SHA256SUMS`.

## Diagnostic and historical review inputs

`mpv-wayland-opengl-color-description.patch` targets mpv 0.41.0. With
`MPV_WAYLAND_OPENGL_COLOR_MANAGEMENT=1`, gpu-next/Wayland OpenGL explicitly
labels its PQ surface. It is a diagnostic reproduction input; the normal build
does not replace system mpv.

`virtio-gpu-hdr.patch` and `linux-source-sha256.json` record the earlier Linux
7.2.5 prototype. They are historical review inputs, not the current DKMS source
or a module to install into the current kernel.

The tested Vivaldi flag `UseDisplaySDRMaxLuminanceNits` removed an extra 100/203
scale on HDR10 PQ video. The package supplies it for Chromium through its
existing backup-managed flags file. Other Chromium-derived apps need their own
supported configuration; user profiles are never overwritten. HLG and AGTM
remain unqualified. See the [brightness evidence](../../docs/evidence/native-opengl-hdr-brightness.md).
