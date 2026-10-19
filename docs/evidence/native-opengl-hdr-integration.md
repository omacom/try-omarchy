# Integrated HDR qualification — 2026-10-18

The code tested here is `02396a4`, on the draft HDR branch reconciled with
upstream v1.0.1 / `0ada4c1`. The launcher-toggle follow-up below changes host
preferences/UI only; the runtime and guest inputs remain the same. The built app uses upstream's ordinary development
identity/version label (0.0.0), not a tagged/notarized release identity.

## Built artifacts

- Normal factory: Omarchy `4.0.0.r7038.gbf9ee5c-1`, Linux `7.2.8-13`,
  Hyprland `0.56.2-7.323`, integration package `0.1.0-27`.
- Hyprland was built from the checked source recipe in an ARM64 builder with
  the declared dependencies; the cached toolchain image override was used.
  The normal factory/package builder was used for the integration archive and
  disk. Source and patch checksums remained enabled. This is not a clean-room
  or bit-for-bit toolchain reproducibility claim.
- Fresh runtime source build: 17 self-contained Mach-O images validated for
  macOS 15. The signed normal app passed strict signature/resource validation
  and 22 Mach-O compatibility checks. Its executable instruction-section hash
  matches the runtime output; whole-file hashes differ because packaging
  re-signs the executable.
- Install/upgrade/removal tests passed against the normal repositories,
  including `try-omarchy 0.1.0-23 → 0.1.0-27`, pacman file checks, DKMS builds,
  preserved disabled/masked units, version monotonicity and package removal.

## Fresh disposable VM

Host: Apple M3 Max, macOS 27.0.1. Disposable VM: 8 vCPUs, 8 GiB, windowed.
The run used the signed app's own launcher/runtime and the final factory,
seeded owner answers, a synthetic account, and separate storage. It did not
modify the working VM. Extra application installation was disabled; the
factory's installed applications and the harness's small package-add check ran.

**97 checks passed, 0 failed, 8 notes, 182 seconds.** The notes included inactive
completed setup units and LibreOffice not closing within the harness's
30-second window; they are not silently counted as failures or fixed here.

- First boot/provisioning completed in 32 seconds. The desktop, terminal,
  browser/local page, file manager and other factory apps started; clipboard,
  notification, recording, theme change and keyboard dispatcher checks passed.
- Guest/host bridges and the shared folder passed. The host received the normal
  integration status report and read the guest's shared-folder write.
- Both first and second cold boots reported the packaged running compositor,
  DKMS DRM selection, **XRGB2101010 / hdredid / SDR reference 100**, and no
  compositor configuration errors. The test window reported 1152×648 near
  120 Hz at scale 2; that is not physical presentation-cadence evidence.
- Calling the unchanged HDR installer did not rewrite its completion state or
  repeat driver/initramfs work.
- Guest-requested shutdown exited cleanly. The second boot reached the desktop
  in 17 seconds, retained the marker file and did not repeat owner provisioning.

A prior fresh run found ten-bit PQ active but SDR reference 203; a subsequent
cold boot of that disk used 100. The host's initial EDID fallback was corrected
to advertise the paired 100-nit reference before Cocoa supplies UI information.
The fresh run above was then repeated and passed without manual guest edits.
This records the observed failure and correction rather than counting that
first run as a success.

## Default SDR and return-to-HDR controls

The same disposable disk then passed an **HDR → SDR → HDR cold-boot** control:

| Host launch | Guest format | Color preset | SDR maximum/reference policy | Rendering probe |
| --- | --- | --- | ---: | --- |
| HDR opt-in | XRGB2101010 | hdredid | 100 | Apple M3 Max VirGL GLES3 / 4× resolve passed |
| Ordinary SDR | XRGB8888 | srgb | 80 | Apple M3 Max VirGL GLES3 / 4× resolve passed |
| HDR opt-in again | XRGB2101010 | hdredid | 100 | Apple M3 Max VirGL GLES3 / 4× resolve passed |

Each control ended with a normal guest-requested shutdown. These are cold
boots, not live HDR/SDR transitions or host sleep/wake tests.

## Repository and GPU tests

The full suite passed before app packaging (432 Swift tests in 89 suites plus
all other suites). Later default `make test` runs on this macOS 27 toolchain
intermittently failed compilation because `TestingMacros` could not be found.
Moving build state aside did not reliably resolve it. The native backend was
also unavailable (`Testing` module missing); no project-wide compiler workaround
was introduced.

Final qualification ran every group successfully:

```sh
# In macos/, using the installed toolchain's actual plugin directory:
swift test --disable-sandbox \
  -Xswiftc -plugin-path \
  -Xswiftc "$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"
# In the repository root, with Swift already qualified above:
make -o test-swift -j4 test-all
```

The explicit-plugin run passed all **432 Swift tests in 89 suites**. All other
repository suites passed. GPU/shared-context Cocoa FP16 checks, SDR gamma,
PQ values, primaries, orientation and ten-bit input passed; the older-SDK
compile-guard path was exercised on this host. HDR/SDR diskless startup, QMP
status and clean exit also passed. `git diff --check` passed.

## Scope and remaining gates

The UEFI/storage/import implementation is unchanged from current upstream,
except for the launcher's HDR option and GPU/display arguments. Existing-guest
package transactions were tested in containers; the user's working VM was not
used for an in-place upgrade trial. The fresh owner flow used the existing
seeded test harness, not a human interaction with the console form.

Actual older-macOS hosts, other Macs/external displays, live mode transitions,
sleep/wake, exact native tone mapping, matched browser photometry, physical
panel nits and physical frame pacing remain open. The earlier
[brightness tables](native-opengl-hdr-brightness.md) belong to the previous
local integration and have not been remeasured on this factory. No new claim
of hardware video decoding or sustained high-resolution playback is made.
Future kernel/compositor source versions require explicit adaptation.

## Repository snapshot timing

The Try Omarchy source base remained `0ada4c1` through qualification. The
rolling Omarchy edge package index advanced while testing ran (including a
new Omarchy development runtime and Omawrite). The factory records the earlier
repository digests and versions stated above; it is not claimed to contain
every package published afterward. The ordinary freshness report exposes
those differences. Its version-difference list also includes the intentional
locally patched Hyprland package versus the repository package. Normal guest
updates remain available; future graphics versions still need adaptation.

## Launcher HDR toggle follow-up

The normal launcher now has a persisted **HDR display** toggle, off by default.
Its saved value controls the existing OpenGL HDR launch option and replaces an
inherited environment value for app launches. Both states retain native
OpenGL/VirGL. The choice applies at the next VM start; it is not a live mode
switch. Direct runtime invocations still accept the development environment
option. Storage, UEFI and previous-VM import code were not changed.

- The complete normal `make build` passed, reusing the qualified factory and
  runtime inputs and rebuilding/signing the app. All 22 Mach-O compatibility
  checks passed. The normal rolling-package freshness notice remains visible.
- `make test` again hit this host toolchain's `TestingMacros` lookup failure.
  The explicit-plugin command above passed **437 Swift tests in 91 suites**;
  `make -o test-swift -j4 test-all` passed every remaining group. New tests cover
  default-off, persistence, malformed/future preference fallback, replacing an
  inherited HDR value while preserving unrelated launch variables, and clicking
  On/Off without launching the VM.
- The rebuilt launcher was inspected on screen. Its HDR label/help fitted the
  existing layout, On/Off interaction worked, and On survived quitting and
  reopening the app. This UI check did not start or alter the working VM.
- A new disposable run with the rebuilt app's own launcher/runtime passed
  **97 checks, 0 failed, 7 notes in 154 seconds** across fresh provisioning and a second cold
  boot. Both boots reported **XRGB2101010 / hdredid / reference 100** with the
  matching compositor and DKMS module, no configuration errors, and unchanged
  installer idempotence. VirGL reported the Mac GPU. Shutdown, persistence and
  the second desktop passed. This harness selects HDR through the direct
  runtime environment; UI preference/launch mapping is tested separately above.

No new physical photometry, other-hardware or live-transition claims are made.

## Linux checksum-output correction

The first hosted Linux package/desktop jobs compiled the HDR compositor but
failed at the host-side manifest write with `SHA256SUMS: Permission denied`.
The container had created that file as root; the unprivileged runner could not
overwrite it. This was an output-ownership failure, not a recorded checksum
mismatch or a recorded missing-command error.

The container now exports only its package. The host writes the complete
manifest once, including `version`. Host generation and cache verification
prefer coreutils `sha256sum`, falling back to `shasum -a 256` on macOS.

- An ARM64 Linux reproduction executed the old/new output stages with a
  synthetic archive, then ran the manifest writer as an unprivileged UID. The
  old stage reproduced the permission error. The new stage produced a
  host-owned manifest; real `sha256sum -c` verified both entries while the
  archive remained root-owned.
- Four build-contract tests exercise isolated checksum-tool paths, complete
  manifest contents, valid cache reuse, and corrupted-cache rebuilding. These
  use a synthetic package/Docker fixture, rather than claiming a compositor
  compilation. The actual companion cache/output path also passed locally.
- All 437 Swift tests passed with the documented toolchain workaround, and
  every remaining repository test group passed. `bash -n` and
  `git diff --check` passed. Hosted build/install/desktop results are tracked
  on the PR separately; local reproduction alone does not qualify those jobs.
