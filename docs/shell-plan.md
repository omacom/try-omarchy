# Shell plan: run upstream Omarchy inside a thin shell

Status: plan of record, 2026-10-15, now implemented on branch
`upstream-shell` (see [Implementation status](#implementation-status)). It
supersedes the earlier research proposal. Facts about upstream were checked
against the repositories and the live package databases on this date.

## Summary

Try Omarchy becomes a thin shell around a normal, upstream-managed Omarchy
install. The guest is a stock generic-`aarch64` Omarchy system installed from
`pkgs.omarchy.org`, it owns its own boot through UEFI and Limine, and
everything Try Omarchy adds lives in one pacman package. Three things then
update on their own schedules through ordinary mechanisms: the Mac app, the
Try Omarchy guest package, and Omarchy itself (kernel included).

The one real limit is that on ARM, Omarchy publishes only to the **edge**
channel for now. `rc` and `stable` follow once a release supports aarch64.

This plan is forward-looking. It defines the system for new VMs; moving
existing VMs onto it is a separate piece of work (see
[Existing VMs](#existing-vms)).

## Implementation status

Branch `upstream-shell`, started 2026-10-15. The app now runs only this
system. The direct-boot launcher, its storage library, boot fixes, migrations,
boot recovery, the integration bundle and the old image pipeline are deleted;
moving existing VMs over is deferred (see [Existing VMs](#existing-vms)).

- **Factory** ([guest/factory](../guest/factory/README.md)): `make guest`
  builds the `try-omarchy` package and then the stock install with the
  pacstrap route below, not the ISO route. The ISO route needs a 6 GB offline
  mirror and an archiso build, and upstream publishes no ARM ISO or VM image
  yet. The install steps mirror upstream's orchestrator, and the result has the
  same layout: btrfs subvolumes, Limine UKI, Snapper, `@factory`, and deferred
  owner provisioning. Output goes to `dist/guest/`.
- **Guest package** ([guest/package](../guest/package/README.md)): every
  integration lives in `try-omarchy`, reading host settings from the
  `tryomarchy.host` credential. The three replaced Omarchy commands, the
  Ghostty/Vivaldi installers, the aarch64-unavailable guards, the pacman
  restore hook and the migrations are not carried over. The JIS mode keys,
  following the Mac's time zone, 1Password Touch ID and the console on
  `hvc0` were added after the first build.
- **Launcher** (`macos/run-qemu-gpu.sh`): UEFI boot with the edk2 firmware
  from the pinned QEMU source (`make firmware`), one `shell/` VM directory
  and a `shell-factory/` cache per storage folder, the bundled `try-omarchy`
  package offered on every boot, storage-folder checks (APFS, free space,
  ownership), bridge supervision with restarts, and cleanup of run
  directories left by a killed launcher.
- **App**: `make app` builds it around the factory. The start menu shows the
  guest's Omarchy, channel and integration versions from
  `dev.tryomarchy.guest`. VM moves and Trash work on the `shell/` layout.

Integration updates became automatic rather than an **Update integrations**
button. The guest installs the offered package only when it is newer than
its own (`vercmp`), so the offer is a no-op for a current guest or one that
already has a newer package.

### Verified on 2026-10-15

On an M2 Pro running macOS 27, using the app's own QEMU runtime and launcher
(`Resources/scripts/run-qemu-gpu.sh` of a shell app build), started from the
command line rather than the app's Launch button, windowed:

- edk2 → Limine → the guest's own `linux-omarchy` 7.2.8 UKI boots. The VM
  has no EL2 on this chip and takes the EL1 path.
- Omarchy's own first-boot owner setup runs on tty1. Its time zone defaults
  to the Mac's. The session then starts with autologin.
- The stock omarchy-pkgs Hyprland 0.56.2 and Quickshell render through
  VirGL. Rounded corners are clean at scale 1 and 2 (checked in `grim`
  captures), so the `rounded-border-coverage` patch is not needed.
- `omarchy-hw-platform` reports `aarch64` and `systemd-detect-virt` reports
  `qemu`. Omarchy applies its own VM toggles (no animations, opaque windows).
- The `tryomarchy.host` credential reaches the guest. The following work:
  keyboard model, time zone, SSH on demand (sshd plus a ufw rule), clipboard
  both ways, Mac audio devices, battery, camera device, guest status reports
  to the app, the menu rows, and the start menu's version row.
- Integration updates: a guest with `0.1.0-1` took `0.1.0-2` from the app at
  boot, and later `0.1.0-3` → `0.1.0-4`. `pacman -U` of a newer package
  inside the guest also works.
- Disk growth: a 20 GiB factory disk opened at 64 GiB grew btrfs online to
  62 GB.
- A fresh VM from the final factory provisioned with Japanese seeded
  (`LANG=ja_JP.UTF-8`). Every integration was up at the first login. The
  factory cache took 9.0 GB on APFS after `--sparsify` (17 GB without it).
- `omarchy update -y` inside the VM ran its whole flow and exited 0:
  snapshot, keyrings, full upgrade, shell restart, mise, AUR. The snapshot
  appears in Limine's Snapshots menu.

Found and fixed along the way:

- The owner is not in the `audio`, `video` or `users` groups, so the ports
  are granted to the active session with `uaccess`.
- Omarchy's firewall blocks port 22, so `ssh-access` opens it while SSH is
  forwarded.
- Omarchy's startup cursor reveal restored the guest cursor.
- The first-boot language marker depended on build order. Seeding now
  follows Omarchy's provisioning-pending marker.

The first launch from the app's own **Launch** button failed: the launcher's
control socket path and the app's direct-boot migration check did not match
the app. Both are fixed.

### Verified through the app on 2026-10-15

A `make app` build, started as the app with its storage-folder override and
**Skip launcher** set, so it took the same launch path as the **Launch**
button. Owner setup ran once from the bundled launcher in a window, since the
app holds QEMU's only control connection.

- The app accepted the launcher's ready line and connected its sleep control;
  every host bridge started, along with the shared folder, port forwarding and
  a USB passthrough setting with no device attached.
- Immersive full-screen: the guest ran at 3024×1900, scale 2, on a 3024×1964
  Retina display, with the guest cursor hidden.
- The guest took `try-omarchy` 0.1.0-8 from the app at boot (from 0.1.0-7),
  and the start menu row showed `Omarchy 4.0.0.r7024.g246f33a-1 · edge`,
  `Integrations 0.1.0-8`, **Current**.
- **Try Omarchy Settings** inside the guest opened the app's settings window.
- The shared folder mounted at `~/omarchy-shared`; a file written in the guest
  appeared on the Mac.
- Mac to guest clipboard, Mac audio devices, battery (95%, fully charged) and
  the camera device. The time zone is recorded as following the Mac
  (`mode: auto`) after owner setup; the setup form defaulted to the Mac's
  zone.
- The settings menu row has its icon; the **Touch ID for 1Password** row is
  present. The JIS key step skipped itself on this ISO Mac.
- Boot output reaches `console.log` through `hvc0`.
- A shutdown from inside the guest ended the session in 6 seconds and left no
  run directory.

Found and fixed during this run:

- Omarchy now ignores the power key (`10-ignore-power-button.conf`) and opens
  its System menu instead, so the app's shutdown request for **Shut Down to
  Manage** and **Restart** never shut the VM down. The package powers off on
  the power key; the VM then stops 6 seconds after the request.
- A screensaver closed before its own exit code ran left the cursor visible.
  The package now hides it again a second after any window closes.

Not verified yet:

- Reset, **Restart** and **Shut Down to Manage**, and moving or deleting a VM
  from the app's windows (no UI automation permission on the test Mac); their
  launcher and QEMU paths were exercised directly.
- Sleep and wake.
- Guest to Mac clipboard in this run (verified earlier in the branch).
- Touch ID for sudo and 1Password, a JIS Mac, and the time zone following a
  change on the Mac.
- Display sync while resizing a window: windowed, the guest started at
  800×600 in a small window.
- An M3+ host with nested virtualization.

Not done yet:

- The nightly CI job.
- Porting the opt-in battery and memory-reclamation smoke tests, which booted
  the old factory's kernel directly.
- The **Managed by macOS** power-profile presentation and the screensaver
  text fit, which needed Omarchy patches.
- **Boot previous snapshot** in the launcher. Limine's menu has it.
- The upstream asks below.
- The issues and backlog in [Known VM issues](vm-issues.md).

## What upstream has today

- **[omarchy#14431](https://github.com/omacom/omarchy/pull/14431), merged
  2026-10-10**, brought the Mac forks' shared work into Omarchy:
  - `omarchy-hw-platform` reports `x86`, `aarch64`, `aarch64-apple`,
    `aarch64-qualcomm`, `aarch64-n1x` or `aarch64-gb10`. A QEMU `virt` guest
    has no `apple,` device-tree compatible, so it is plain `aarch64`.
    `omarchy-hw-vm` (systemd-detect-virt) already exists, and
    `install/user/hardware/vm-no-animations.sh` uses it.
  - `omarchy-pkg-defaults` composes the package set per platform;
    `default/pacman/aarch64/` holds the ARM pacman templates
    (`[omarchy]` at `pkgs.omarchy.org/edge/$arch`, Arch Linux ARM from
    `arm-mirror.omarchy.org`). `omarchy-channel-set` refuses a channel the
    platform has no template for.
  - Lifecycle dispatch (`docs/lifecycle-dispatch.md`): plain `aarch64`
    registers no platform package, so provisioning, factory reset and
    `omarchy update` take the generic Limine path, as on Snapdragon and the
    aarch64 ISO.
  - The image-target manifest (`/var/lib/omarchy/image/target`) lets an image
    built elsewhere defer hardware setup and keyring creation to first boot.
  - Platform data lives at `/usr/share/omarchy-platform/` (key names, display
    cutouts, display and audio hints, keyrings), read by Omarchy at a fixed
    path with no platform branch in its code.
- **[omarchy-pkgs](https://github.com/omacom/omarchy-pkgs)** publishes to
  `https://pkgs.omarchy.org/edge/aarch64`: `omarchy` 4.0.4, `omarchy-dev`,
  `omarchy-settings`, `omarchy-settings-dev`, Omarchy's own aarch64 `hyprland` 0.56.2, `aquamarine`,
  `hyprtoolkit`, `hyprland-guiutils`, `quickshell`, `linux-omarchy` 7.2.8 with
  headers, `ghostty`, `mise-bin`, `yay`, `ttfx`, `voxtype-bin`, `1password`,
  `omarchy-chromium-bin`, `walker`, and the Mac bare-metal packages.
  - The kernel config (`pkgbuilds/linux-omarchy-aarch64/config.aarch64`)
    enables virtio block, net, console, GPU, input, sound, balloon with page
    reporting, 9p, virtiofs, KVM, the EFI stub and 4K pages: every device the
    app uses.
  - `rc` and `stable` carry only fast-ring vendor packages for aarch64. No
    `omarchy`, Hyprland or kernel yet.
  - On edge, `omarchy-channel-set edge` installs `omarchy-dev` and
    `omarchy-settings-dev`, built from the `quattro` branch. The `omarchy`
    4.0.4 release package there predates the aarch64 platform work (no
    `omarchy-pkg-defaults`, platform detector or image-target support), so an
    ARM guest runs the development line until a release carries it.
  - `arm-mirror.omarchy.org` mirrors the live Arch Linux ARM repositories
    with no frozen snapshot; every channel shares it.
- **[omarchy-iso#258](https://github.com/omacom/omarchy-iso/pull/258), merged
  2026-10-15**, builds one aarch64 ISO for every UEFI board on
  `linux-omarchy`. Upstream CI installs it unattended in QEMU (`virt`,
  edk2 pflash, virtio-gpu, Limine UKI) on Apple Silicon Linux runners and
  boots the result.
  - Unattended installs read the configurator's answers from a drive labeled
    `cidata` (`configs/airootfs/usr/local/bin/omarchy-cidata-load`). A
    `defer-provisioning` marker in place of credentials defers user creation
    to first boot, which is what our factory needs.
  - `test/vm-image/vm-seal` turns an installed disk into a downloadable image,
    and the x86 nightly (`https://nightly.omarchy.org/edge/latest.json`)
    publishes a `.qcow2` plus unpacked `vmlinuz`, `initrd` and `cmdline` for
    direct boot. The ARM nightly is not published yet.
- **The official Mac image** (`omarchy-mac-installer/image-builder`) is for
  bare-metal Apple Silicon: Aurora kernel, m1n1 and U-Boot, Asahi
  repositories, LUKS re-keying through `omarchy-mac-boot`. In a VM the
  detector says `aarch64`, none of those hooks fire, and the Aurora kernel
  does not target `virt`. It is not a base for us; the package mirror is.

## Why the earlier guest was fragile

This section describes the direct-boot guest the plan replaced; the files it
names no longer exist in this branch.

Updates are not blocked inside today's guest. They are held back in several
ways, and that is where the maintenance cost comes from:

- **Omarchy is not installed as a package.** A pinned git tree is copied into
  the image and registered as `try-omarchy-runtime`, which claims to be
  `omarchy` (`guest/scripts/register-omarchy-runtime.sh`). Channel switching
  is impossible.
- **We patch Omarchy's own files.** 21 patches under `guest/patches/omarchy`,
  and three Omarchy commands replaced in `guest/native-overlay/usr/bin/`.
- **Key packages are frozen.** `IgnorePkg` holds the kernel, Hyprland,
  Aquamarine, Hyprtoolkit and `hyprland-guiutils`; Hyprland is a custom
  source build.
- **A hook undoes Omarchy's repository settings.**
  `guest/fragments/pre-refresh-pacman-restore-arm.sh` restores our
  `pacman.conf` after Omarchy writes its templates.
- **The kernel lives outside the guest.** QEMU direct-boots a host-side
  kernel paired with each disk (`macos/run-qemu-gpu.sh`), so the guest cannot
  update its own kernel, and host settings travel on a kernel command line
  that ARM truncates at 2048 bytes.
- **Side packages are pinned by us.** mise, yay, ttfx, voxtype, ghostty and
  Vivaldi are built or vendored here; all but Vivaldi are now on edge.
- **So we need our own migration system.** `GuestBootFixes.swift` and
  `guest/migrations/catalog.json` exist only because the guest cannot fix
  itself through updates.

## Target architecture

### 1. The guest is a stock `aarch64` Omarchy install

Build the factory with Omarchy's real installer: run the official aarch64 ISO
unattended in CI with a `cidata` drive carrying our answers and the
`defer-provisioning` marker, then seal the result into a VM image. This is
upstream's own pipeline, so the guest is byte-for-byte what a real install
produces: btrfs root, Limine UKI, Snapper, the `aarch64` package set from
`omarchy-pkg-defaults`, upstream pacman templates, no user until owner
provisioning runs on first boot. Nothing under `/usr/share/omarchy` is ours.

Pin the edge database snapshot each factory is built from, for reproducible
builds and provenance, even though guests update freely afterwards. Once
upstream publishes an ARM nightly VM image, the app can download and verify
that instead of us building it; ask for it directly, since both projects live
in the same organization.

If the ISO route proves awkward in CI, the fallback is the route the Mac image
builder takes: pacstrap from the pinned databases, write the image-target
manifest with `platform=aarch64`, and run upstream
`omarchy-apply-system --defer-provisioning --first-install` in the chroot. It
produces the same system; the ISO route is preferred because it reuses
upstream's installer and tests unchanged.

Disk encryption stays off in the VM: the host disk is already under APFS
protection and a second passphrase adds nothing.

### 2. The guest owns its boot

QEMU boots `virt` with the edk2 aarch64 firmware on pflash (code read-only,
one vars file per VM) into Limine on the disk's ESP, exactly as upstream's
ISO tests do. The kernel updates through pacman, the Limine mkinitcpio hook
rebuilds the UKI, `omarchy update` verifies the boot chain, and the user
reboots the guest. Snapper snapshots plus `limine-snapper-sync` give Omarchy's
own rollback from the boot menu.

This removes the boot kit, the recovery initramfs, the paired-kernel
validation and the kernel hold. The existing `qemu-hvf-mapped-sections.patch`
already handles pflash ROMD transitions under HVF. The firmware is built from
the QEMU source we already compile and must be shipped in the runtime bundle,
which currently has none.

The app keeps a recovery path: it can still direct-boot a known kernel and
initramfs (the nightly's unpacked files show upstream expects both), and the
launcher exposes **Boot previous snapshot** through Limine's entries.

### 3. Host-to-guest configuration uses systemd credentials

The kernel command line is the guest's now. The `tryomarchy.*` and
`omarchy.*` tokens (shared folder name, SSH access, keyboard geometry, locale,
time zone, VirGL flags, fixes bundle) move to systemd credentials delivered by
QEMU over SMBIOS type 11 (`-smbios type=11,value=io.systemd.credential:...`)
or fw_cfg. systemd imports them natively, there is no length limit, and the
settings boot credential already uses this mechanism. Guest units read
`$CREDENTIALS_DIRECTORY` instead of `/proc/cmdline`.

### 4. One `try-omarchy` guest package

Everything Try Omarchy adds becomes a single pacman package: clipboard, audio,
camera, battery (bridge agent and DKMS module), Touch ID PAM module and broker,
time zone and locale seeding, shared-folder mount and link units, display sync,
settings port, SSH generator, pinch and Apple keyboard input rules, fcitx
defaults, menu extensions.

Rules for the package:

- It never edits files owned by `omarchy` or `omarchy-settings`. It
  customizes through drop-ins, environment files, `/etc/skel` extensions,
  `omarchy-hook` and the platform root.
- A VM has no platform package, so it may provide `omarchy-platform` and
  populate `/usr/share/omarchy-platform/` with Mac key names and display
  hints, which Omarchy reads without a patch. Confirm with upstream that a
  virtual platform package is welcome there.
- It is published in `omarchy-pkgs` to `edge/aarch64`, so it arrives through
  `[omarchy]` like any other package, survives Omarchy's channel refresh, is
  signed with Omarchy's key, and is upgraded by `omarchy update`. Package-only
  PRs merge when green and publish within minutes.
- The app also carries the same package file for offline first boot and so an
  app can raise the guest to its own version without network.
- It depends on `linux-omarchy-headers` for the DKMS module.

### 5. The Mac app

The launcher, QEMU runtime and Swift bridges ship as today (DMG, later
Sparkle). Replacing the app never touches the guest disk. On each launch the
guest reports its `try-omarchy` package version over the settings port; when
the app wants a newer one it offers **Update integrations**, which starts a
boot credential service that installs the package through Omarchy's pacman
wrapper (`omarchy-update-pacman`, so the raw-pacman guard allows it). No
consent catalog, preimages or file journals remain; pacman and its hooks do
the work.

## The update model

| Piece | Ships through | Who triggers it |
| --- | --- | --- |
| Mac app | DMG / Sparkle | User installs the app |
| `try-omarchy` guest package | `[omarchy]` edge; copy in the app as fallback | `omarchy update` in the guest, or **Update integrations** in the launcher |
| Omarchy, Hyprland stack, kernel | `[omarchy]` and Arch Linux ARM via `omarchy update` | User, inside the guest |

Version skew is handled by protocol, not by files: every virtio port
advertises a protocol version in its handshake, the app supports the current
and previous guest package, and the guest ignores ports it does not know. A
user who updates only the app sees new launcher features immediately and is
offered the guest update. A user who updates only inside the VM gets the new
guest package with no host bridge until they update the app, which the bridges
already tolerate.

The app cannot force `omarchy update`; it is interactive and runs as the user
with sudo. The launcher can show the guest's update-available state and open a
terminal into it, and that is enough.

Channels are whatever upstream offers. `omarchy-channel-set` works out of the
box, including `dev`, which follows a git checkout. Stable and rc appear for
ARM when upstream publishes them; the app defines no channels of its own.

## Disposition of the current patches and overlays

| Item | Disposition | Reason |
| --- | --- | --- |
| `shell-qtquick-611` | Drop | omarchy#14845 merged 2026-10-10 |
| `update-restart-arm-kernel` | Drop | `omarchy-update-restart` handles `modules.builtin` (#12440) |
| `ghostty-arm64-terminal`, pinned ghostty build | Drop | `ghostty` on edge; `omarchy-install-terminal` offers it |
| `1password-arm64-installer`, Touch ID agent for 1Password | Drop / move to package | `1password` on edge; agent is ours |
| `notification-hover-close`, `notification-screen-privacy` | Verify, then drop | Check current `quattro` shell |
| `*-aarch64-unavailable` (pkg-add, AUR, Dropbox, GeForce NOW, Battle.net, Lutris) | Upstream | Should become `omarchy-hw-x86` predicates |
| `vivaldi-browser-integration`, `vivaldi-menu-entries`, Vivaldi RPM repack | Upstream | Recipe for `omarchy-pkgs`, then menu entries upstream |
| `update-free-space-message`, `first-run-update-notification` | Drop | Guest-specific wording no longer needed |
| `touch-id-sudo-menu`, `mirror-macos-timezone`, `macos-power-profile`, `keyboard-us-acentos` | Rewrite as add-ons | Menu extensions, hooks, platform root, or upstream where generic |
| Hyprland `rounded-border-coverage` | Test unpatched, then upstream | Not covered by omarchy-pkgs' four Hyprland patches; the software-renderer patch matches only llvmpipe/softpipe |
| Pinned mise, yay, ttfx, voxtype | Drop | All on edge |
| Replaced commands (`omarchy-audio-input-set-default`, `omarchy-screensaver`, `omarchy-theme-bg-switcher`) | Rewrite or upstream | No command replacement in the new guest |
| `pre-refresh-pacman-restore-arm` hook | Drop | Upstream ARM templates |
| Migration catalog and boot-fix runner | Retire | Replaced by the package and pacman |

After this the only guest-side state the app checks is "is `try-omarchy`
installed and at least version N?"

## Guardrails

- Snapper snapshot before every update, with Limine snapshot entries exposed
  by the launcher.
- A recovery kernel path in the app for a guest that cannot boot its UKI.
- A nightly CI job that installs current edge Omarchy plus the `try-omarchy`
  package in the real QEMU/HVF runtime and exercises every host-guest port,
  VirGL rendering and nested virtualization, so upstream breakage is seen
  before users see it.
- Protocol versioning on every virtio port, tested against the previous
  release of both sides.

## Risks to accept

- **Edge only on ARM.** Every ARM user follows edge until upstream ships ARM
  to stable. Edge moves daily; snapshots are the safety net.
- **No frozen base repositories.** All channels share live Arch Linux ARM, so
  a Mesa or kernel change can reach users without an Omarchy release. The
  nightly CI job and rollback cover this; version pins do not.
- **Kernel cadence is not ours.** `linux-omarchy` for aarch64 is
  `skip_build` in omarchy-pkgs, built and uploaded by upstream on their
  schedule.
- **VirGL compatibility of the stock Hyprland is unverified** until the spike
  runs.

## Existing VMs

Today's disks are ext4 with no ESP, hold a stand-in `omarchy` package and a
held kernel. In-place conversion to btrfs, UEFI and real packages is not
realistic. The plan for them, after the new system ships: keep the old launch
path working for old disks, create a new VM on the new system, and move the
user's home, packages and settings over with an export-and-import flow of the
kind `try-omarchy-windows` already has. The old disk stays until the user
deletes it. Details are deferred until the new system is stable.

The current implementation dropped the old launch path rather than keeping it:
this version of the app does not boot `disks/` or `boot/` and leaves them on
disk untouched. Instead of an export-and-import flow, the launcher attaches
the old root read-only to the new VM, and `try-omarchy-import-previous` copies
the user's files and reinstalls their packages there.

## Phases

1. **Spike (one to two days).** Build the aarch64 ISO from omarchy-iso
   `master`, install it unattended under our QEMU/HVF runtime with edk2 and
   VirGL, record what breaks with none of our patches. Specifically check
   stock Hyprland rendering, the EL2 nested-virt probe with pflash firmware,
   balloon page reporting, audio and the 9p share.
2. **New factory.** CI builds the ISO-installed, sealed image with the
   `defer-provisioning` marker and a pinned edge snapshot; the runtime bundle
   ships the edk2 firmware; the launcher boots new VMs through UEFI. Old disks
   keep the direct-boot path.
3. **`try-omarchy` package and credentials.** Move the overlay into the
   package, replace kernel tokens with systemd credentials, add the version
   handshake and **Update integrations**. Publish to `omarchy-pkgs`.
4. **Upstream and delete.** Send the Vivaldi recipe, the x86-only
   predicates and the Hyprland patch upstream; delete `guest/patches`,
   `guest/native-overlay`, the migration catalog and the boot-fix runner for
   new disks.
5. **Existing VMs.** Export-and-import flow, then retire the old launch path
   when usage allows.

## Open questions for upstream

- Publish an ARM nightly VM image from the existing `vm-seal` pipeline.
- Accept `try-omarchy` in `omarchy-pkgs`, and whether a virtual platform may
  provide `omarchy-platform`. The package already links one file there,
  `display-cutouts.json`, for the Mac's camera notch
  ([camera notch](camera-notch.md)).
- ~~Take the Hyprland border-coverage patch into the aarch64 Hyprland
  recipe~~: not needed; stock Hyprland renders cleanly in the VM.
- A sanctioned place for a package to add Hyprland configuration and menu
  rows. `try-omarchy` uses the user's toggles directory and a one-time edit
  of the menu extension file today. Alternatives would be a lifecycle
  registration (`setup-user`) for a VM integration package, or system-wide
  drop-in directories.
