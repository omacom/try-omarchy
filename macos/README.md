# Native macOS app

This directory contains the Apple Silicon application layer:

- a Swift/AppKit lifecycle and permission helper;
- a pinned, patched QEMU ARM64 runtime using HVF and Cocoa/VirGL, plus the edk2
  UEFI firmware from the same QEMU source;
- the VM launcher (`run-qemu-gpu.sh`) and the input, audio-device, camera,
  clipboard, shared-folder, signing, and DMG tooling.

Use the root Makefile for normal development:

```sh
make runtime   # macos/.build/qemu-gpu-runtime
make firmware  # macos/.build/firmware (edk2-aarch64-code.fd and its license)
make app       # dist/app.noindex/Try Omarchy.app
make run
make package   # signed and notarized dist/TryOmarchy.dmg
make release   # prompt for version, tag, and build a signed/notarized DMG
make release VERSION=vX.Y.Z  # explicit version without prompting
make test
```

`make app` ensures `dist/guest/` (the factory and the `try-omarchy` package),
the staged QEMU runtime and the firmware are current first.

The staged runtime is a complete, checksum-pinned Apple Silicon closure built
for macOS 15.0. Runtime and app assembly do not resolve libraries or `zstd`
from the host Homebrew prefix, so building on a newer macOS release cannot
silently raise the app's deployment target. VirGL 1.3.0 is built from source
with the pinned startergo 1.0.42 patch set and its dual-source shader regression
tests; ANGLE 1.0.16 and libepoxy 1.0.5 retain their Sequoia bottles. This keeps
the dual-source shader fix for accelerated terminals without bundling the
Tahoe-only VirGL bottle.
The launcher selects native macOS OpenGL (`cocoa,gl=on`). The local VirGL
OpenGL compatibility patch preserves real sample counts and falls back to mutable
multisample textures when immutable multisample storage is unavailable. This
restores default browser acceleration through the shared VM graphics device.
It also selects integer attributes for native Apple GL and avoids duplicate
alpha and BGRA channel conversions. The build runs the actual format-probe regression with controlled GL entry
points, alongside the upstream shader and blend tests.
VirGL uses `debugoptimized` (`-O2`) with assertions enabled, retaining diagnostics
without shipping an unoptimized graphics command path.

To leave capacity for other host applications during a runtime rebuild, use
`OMARCHY_RUNTIME_BUILD_JOBS=2 make runtime`. The override bounds Ninja compilation
for VirGL, libslirp, and QEMU; otherwise Ninja selects its usual parallelism.
See [performance profiling](../docs/performance.md) for CPU/memory accounting,
reproducible measurements, and the current native-comparison limitations.

`make release` defaults to the maintainer's Developer ID Application identity
and `try-omarchy` notarytool profile. It offers patch, minor, or major selection
and direct version entry (or accepts `VERSION=vX.Y.Z`), ensures the guest and
runtime are current, and creates an annotated release tag before building the
app and DMG. It requires a clean checkout and reuses an existing tag only on the same
commit, so failed
notarization can be retried. See [releasing](../docs/releasing.md) for version
selection and publishing. The app builder is also directly usable for release
signing and notarization:

```sh
macos/build-app.sh \
  --configuration production \
  --dmg \
  --guest-dir dist/guest \
  --sign-identity "Developer ID Application: Example (TEAMID)" \
  --notarize-profile try-omarchy
```

Local app builds appear as **Try Omarchy Dev**, with bundle ID
`dev.tryomarchy.native.development`. They automatically select an installed
Apple Development certificate (or Developer ID Application if no development
certificate is available), so Accessibility, Camera, and Microphone grants can
survive rebuilds after you grant them once. Production keeps
`dev.tryomarchy.native` and its own privacy decisions. The first development
build with this new identity needs fresh grants.

`make build`, `make app`, and `make run` all use this development identity;
opening the generated `.app` directly works the same way. Development signing
is local, with secure timestamping disabled, and does not notarize the app.
Production keeps secure timestamping and the release notarization workflow.

If several eligible certificates are installed, choose one explicitly:

```sh
make run DEVELOPMENT_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
```

`make package` uses `PACKAGE_SIGN_IDENTITY` and `PACKAGE_NOTARY_PROFILE`, which
default to the configured release credentials. It fails instead of producing
an unnotarized fallback.
Production assembly goes to `dist/release.noindex/Try Omarchy.app`, leaving the
development bundle in place. Without an installed certificate, development
stops with setup instructions instead of silently invalidating existing grants.
Create an Apple Development certificate in Xcode to enable persistence, or use
`DEVELOPMENT_SIGN_IDENTITY=-` when intentionally testing ad-hoc builds.
Runtime caches are private to `macos/.build/`; user-facing output always goes
to `dist/`. The generated app lives inside `dist/app.noindex/`, which keeps a
development build from appearing beside an installed copy in Command-Space.

Normal app launches and `make run` maintain one VM under
`~/Library/Application Support/Try Omarchy/VM/v1`: its disk and UEFI variable
store in `shell/`, and the decompressed factory, kept once per factory, in
`shell-factory/` (see [VM storage](../docs/architecture.md#vm-storage)). The
VM boots its own kernel through UEFI and Limine and updates itself, so app
updates reuse the disk as it is. Use `make reset` to replace it with the
current factory or `make run-ephemeral` to test that factory without retaining
its disk. VMs left by earlier direct-boot versions (`disks/`, `boot/`) are
ignored.

Reset Omarchy is a confirmed, user-facing flow.
That destructive flow keeps **Reset** disabled until the user types
`Try Omarchy` exactly in a native sheet. Cancelling or dismissing the sheet
returns control without invoking the storage reset. During reset, the disabled
button names the current phase: checking the VM, deleting it, then finishing
the reset. The next launch prepares a new disk if needed, with its button
showing checking, image preparation, setup, and startup phases.
Phase changes come from the launcher process and are also announced to VoiceOver.

The launcher's **Selected VM → Manage…** sheet shows the current selection,
explains switching, moving, creating a separate VM, and deletion, and returns to the
launcher with **Done**. Selection is saved immediately but does not start a
VM. New selection requires an empty folder; existing selection requires a
VM disk (`shell/disk.img`) and workspace marker.

Relocation runs `--copy-vm SOURCE EMPTY_DESTINATION` in a separate process,
binds it to the source displayed in the sheet, holds the launcher's lock on
`shell/lock`, stages a private sibling copy without the rebuildable
`shell-factory/` cache, and verifies every file with SHA-256
before atomic publication. Structured stderr records report copy phases and
actual hashed-byte verification progress. The sheet remains open, disables
Done and selection while busy, and displays errors or the final selected and
recovery paths inline. The original is retained; the preference changes only
on success. APFS clones are used on the same volume, and sparse copying across
volumes. Both locations must be local APFS folders. Symlinks, hard links,
special files, occupied destinations, and changes during copying are refused.

**Delete VM…** uses the same danger styling and typed `Try Omarchy` confirmation
as Reset, and confirms the exact selected folder and moves its complete workspace
into macOS Trash under the same launcher lock. It keeps other VM copies and
refuses a running or changed VM. The folder remains selected, so choose another
VM or an empty folder afterward. Trash errors never trigger permanent removal.

The choice is stored in `UserDefaults` and published to the launcher as
`OMARCHY_QEMU_GPU_STATE_ROOT`. An inherited value still wins and disables
location changes in the launcher. Reset composes its environment exactly as launch
does, so it always erases the workspace the user is actually running.

**Skip launcher** is stored in the versioned `launcher-settings.json` file at
that workspace's root (normally `~/Library/Application Support/Try Omarchy/VM/v1`).
It defaults to off when the file is missing, unreadable, or invalid. The old
`startAutomatically` UserDefaults value is ignored; existing users must enable
Skip launcher again. Release and development apps using the same workspace
share this choice. Selecting another workspace uses that workspace's setting.
A choice made before the first VM starts is held in memory and saved after the
storage backend initializes the workspace. Missing persistent disks and
`--ephemeral` sessions always show the launcher. Factory Reset preserves the
workspace setting, but the missing disk forces the next launch through the
launcher; deleting the whole workspace removes the setting too.

Reset deletes the VM's disk, variable store and status without creating a
replacement. A release app first downloads the compressed factory into
`shell-factory/` when a new VM needs it (`FactoryImageDownload.swift`, see
[VM storage](../docs/architecture.md#vm-storage)); development builds carry it.
To test the download with a development build, pass
`--factory-download-url http://127.0.0.1:PORT/` to `build-app.sh` and serve
`dist/factory/` from a server that supports range requests.
On the first launch of a factory, the launcher verifies the
compressed disk's SHA-256 digest, checks free space, decompresses it into
`shell-factory/`, and returns its zero blocks to APFS
(`omarchy-vm-helper --sparsify`). Every new VM is an APFS clone of that file.
A disposable session clones the same file into its own temporary folder
(`OMARCHY_QEMU_GPU_FACTORY_CACHE`). The launcher refuses storage folders that
are not APFS, not owned by the user, or too broad, before it touches them.

The Resources editor stores CPU count, RAM, and an optional maximum disk capacity in the versioned
`vmResourcePreferences` UserDefaults value. Until the first save, it adopts the
existing `memoryPreferences` choice without rewriting it. CPU choices range
from 4 through all host cores. Memory recommends 8 GiB on hosts with at least
16 GiB. Choices start at 4/6/8 GiB and continue in 4 GiB steps, keeping at least
4 GiB for macOS; larger allocations that leave less than 8 GiB carry a
performance note. Saved values that no longer
fit resolve independently to their defaults without rewriting storage.

The app exports `OMARCHY_QEMU_GPU_CPUS` and the established
`OMARCHY_QEMU_GPU_MEMORY_MIB`, replacing inherited overrides with the displayed
selection. The launcher validates these before touching VM storage. Direct
script invocations retain the 2048 MiB minimum and the 4 GiB host floor for
allocations above the default. The optional `OMARCHY_QEMU_GPU_DISK_GIB` selects up to 8192 GiB of sparse
capacity. New resource settings default to 64 GiB; existing saved preferences
without a disk maximum retain their capacity. Use Defaults selects at least
64 GiB and never reduces a larger existing disk. The launcher grows the disk
file sparsely under the VM's lock and never shrinks it;
`try-omarchy-grow-root.service` grows the root partition and btrfs to fill the
disk at boot. Storage-only resets strip all three resource keys. Changes apply on the next launch without rebuilding
or re-signing the app.

Port forwarding is one versioned generic mapping list. The editor's **Add SSH**
action only inserts the ordinary TCP `2222 → 22` preset; users may edit it like
any other mapping. The signed shell parser remains the sole QEMU `hostfwd`
builder and derives the boot's `tryomarchy.ssh_access=1` setting only from a
fully valid TCP mapping to guest port 22. No SSH-specific preference, port probe, status code, or
parallel forwarding path exists.

Ad-hoc signing identifies one exact build, so macOS intentionally invalidates
its privacy grants when that build is replaced. The app's **Open Settings**
action repairs a stale Accessibility entry and registers the installed build,
and scopes the repair to the running app's bundle ID. A stable Apple Development
or Developer ID signature is required for the grant to survive future updates.

See the root `README.md`, `docs/architecture.md`, and `docs/releasing.md` for the
supported platform, runtime boundaries, and distribution checklist.

## Audio continuity

At launch, the native helper queries CoreAudio for the nominal sample rate of
each effective SDL route. Saved speaker and microphone selections take
precedence over the Mac's separate defaults; a disconnected selection falls
back to its direction's default. Duplicate SDL device names retain their
numbered suffixes. Output and input mixer rates are set independently, with a
48 kHz fallback if a rate cannot be read. This mitigates the reported playback
speed issue at 44.1 and 48 kHz; rates stay fixed until the VM is restarted, and
other rates and live route changes still need playback validation.

The SDL backend uses a 1 ms audio timer and eight output buffers. With an
obtained 512-frame SDL callback at 44.1 kHz, that gives 4096 frames (about 93 ms)
of host queue capacity; other devices may negotiate different values. Capacity
is not guaranteed occupancy or a measurement of end-to-end latency. The shorter
timer increases requested wakeups while audio is active.

The pinned QEMU build also preserves a full HDA output ring instead of discarding
its queued samples after a delayed callback. It rebases the producer clock to
the existing write position and drains through the normal bounded backend write
loop, avoiding a prolonged elapsed-time catch-up burst. Existing clock correction
and stream start/stop behavior remain in place. The optional
`hda_audio_full_recovery` QEMU trace event identifies this recovery path.

These changes mitigate audio interruptions when graphics work delays device
servicing; they do not remove blocking graphics work or guarantee uninterrupted
playback under every load. See [audio validation](../docs/audio-continuity.md)
for the reproduction procedure, observations, and latency limitations.

### Remote keyboard text injection

Cocoa translates directly representable printable ASCII text supplied with a
placeholder key code by remote-control tools into balanced guest key presses.
Translation uses the current Mac keyboard layout, so the guest layout must
match it. Physical-key events and Command/Control/Option shortcuts retain their
normal behavior. Unsupported batches (including non-ASCII text, control
characters, characters on dead keys, or text requiring a currently held key or
more queue space than is available) are ignored as a whole rather than producing
stray A presses or partial text. Accepted characters are paced through QEMU's
input queue so long batches do not overflow the virtual keyboard. This is not a
Unicode/IME input bridge: characters requiring Option/AltGr or dead-key
composition are not supported.
