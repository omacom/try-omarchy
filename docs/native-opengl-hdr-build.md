# Building the integrated OpenGL HDR draft

This draft is based on upstream v1.0.1 (`0ada4c1`). It retains upstream's UEFI
boot, GPT/Btrfs factory, normal VM storage location, integration update offer,
and read-only previous-VM import flow. No alternate launcher or VM directory
is required. The normal default remains SDR; enable **HDR display** in the
launcher to opt in. The choice is saved and applies the next time the VM starts.
Both settings use the accelerated native OpenGL path. HDR requires a supported
Mac display and the paired HDR guest integrations described below.

```sh
make build
open -n -a "$PWD/dist/app.noindex/Try Omarchy.app"
```

The launcher’s saved choice overrides an inherited `OMARCHY_NATIVE_OPENGL_HDR`
variable, so its displayed state matches the next app launch. Direct
`run-qemu-gpu.sh` invocations still accept `OMARCHY_NATIVE_OPENGL_HDR=0|1` for
runtime development and disposable tests. This is a cold-start setting, not a
live SDR/HDR switch.

Save and shut down any other copy of this app before launching against the same
storage folder. Use the normal launcher to select another storage location for
a disposable test. Do not copy a legacy direct-boot disk over the new UEFI disk;
use **Import Previous VM** exactly as in upstream.

## What the normal build includes

- `make guest-package` builds the pinned Hyprland 0.56.2 source recipe in an
  ARM64 container, checks source/patch digests, and embeds the resulting
  `hyprland-0.56.2-7.323-aarch64.pkg.tar.zst` plus its digest in the integration
  package's `/usr/share/try-omarchy/hdr/`. No binary package is tracked in Git.
  The recipe retains the four upstream packaging fixes and adds the two HDR
  patches. Its source-built output is cached by recipe and builder-image ID;
  `FORCE=1` bypasses that cache. Runtime dependencies still resolve from the
  normal signed Omarchy/Arch repositories; this is not a fully locked toolchain.
- The integration package ships checksum-inventoried Linux 7.2.8 virtio GPU
  sources with the private HDR extension, GPL licensing, and DKMS metadata.
  It builds only for 7.2.8 Omarchy package releases with matching headers.
  Depmod selects the override, and initramfs is regenerated. New kernel source
  versions require an explicit adaptation, rather than loading a foreign module.
- `hdr-install` uses **pacman**, outside any pacman install hook, to install the
  companion as the ordinary `hyprland` package. Pacman retains file ownership
  and dependency checks. It accepts the supported 0.56.2 upgrade range and
  refuses downgrades or unqualified compositor versions. It never downloads
  dependencies during the pre-login update. Missing/incompatible dependencies
  fail the update rather than triggering an implicit system upgrade.
- The factory invokes the same installer after its normal local package
  transaction, deferring initramfs generation to upstream’s final UKI step. Existing UEFI guests get it through the existing **Update
  integrations** offer and pre-login service. Restart after the first driver
  installation: an already loaded stock driver is not hot-unloaded.
- EDID supplies mode/refresh/SDR-white policy, including the paired 100-nit
  fallback before the host window has supplied UI information. PQ output selects ten-bit
  `hdredid` and the host's paired 100-nit reference; SDR selects eight-bit sRGB.
  Explicit per-output user monitor rules still win. No user's monitor file,
  app profile, theme or imported home configuration is replaced.
- Chromium's package-owned flags include `UseDisplaySDRMaxLuminanceNits` to
  avoid the tested PQ-video reference scaling. Existing edited backup files
  follow normal pacman `.pacnew` behavior. Other Chromium-derived apps may need
  the same flag through their own supported configuration; Vivaldi was tested
  separately. The diagnostic mpv patch is not installed as a system player.

## Boundaries

This draft deliberately replaces the supported compositor package and supplies
an out-of-tree DRM driver. It is not a stock-graphics guest. Normal Omarchy
updates may advance beyond these tested source versions; another source/ABI
adaptation is then required. Removing the integration package removes its driver sources and DKMS module;
the separately installed Hyprland package remains installed. To return that
component to upstream, reinstall the repository’s `hyprland` package through
normal package management and reboot.

No broad package hold, global downgrade, custom
storage namespace, or replacement migration implementation is introduced.

Driver/compositor/installer changes invalidate the factory cache as well as the
integration package cache. Source and build artifacts are distinct from the
[physical measurement evidence](evidence/native-opengl-hdr-brightness.md),
which was collected on the earlier local integration. Exact-branch factory and
runtime results must be recorded separately; those historical observations do
not automatically qualify a newly built image.

## Exact-branch qualification

See the [integration qualification record](evidence/native-opengl-hdr-integration.md)
for the final factory/app versions, 97-check disposable run, SDR/HDR cold-boot
controls and the local Swift toolchain test workaround. These results do not
replace the remaining physical-display and other-hardware gates.
