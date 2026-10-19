> Draft HDR exception: this branch adds a source-built compositor package and
> an out-of-tree driver through the existing package/factory flow. See the
> [HDR build contract](native-opengl-hdr-build.md). Storage and migration stay
> on the upstream flow described here.

# Architecture

Try Omarchy packages four pieces into one macOS app:

1. A small Swift/AppKit launcher for the macOS side.
2. A patched QEMU runtime and the edk2 UEFI firmware that create and run the
   virtual machine.
3. A factory disk: a stock generic-`aarch64` Omarchy install from Omarchy's
   own package repositories.
4. The `try-omarchy` guest package, which carries every Mac integration.

```text
Try Omarchy.app
└── Swift/AppKit launcher
    └── QEMU + Apple Hypervisor Framework + edk2 UEFI firmware
        └── Limine → the guest's own linux-omarchy UKI
            └── stock aarch64 Omarchy + try-omarchy package
                └── Omarchy desktop
```

The guest is an ordinary Omarchy system. It updates itself with
`omarchy update`, including its kernel, and can switch channels with
`omarchy-channel-set`. Try Omarchy changes no file Omarchy owns.

## What happens when the app opens

The Swift launcher presents a start menu on every app open. It reports optional
macOS Accessibility, Microphone, and Camera permission state, handles confirmed factory
resets, startup, shutdown, and host audio devices. It prepares a writable copy
of the factory disk and starts QEMU. QEMU's Cocoa input layer uses the shared
Accessibility grant to capture system-wide Command chords and deliver Command
as guest Super. Swift does not replace QEMU or run the Omarchy desktop itself.

QEMU presents the hardware that Linux expects: CPUs, memory, storage, networking,
graphics, audio, keyboard, and pointer devices. Because both the Mac and the
guest are ARM64, Apple Hypervisor Framework runs the guest CPU instructions on
the Apple Silicon processor. QEMU provides the virtual devices around that CPU.

The balloon device enables free-page reporting. Linux keeps the selected RAM
capacity but reports unused ranges, which the patched HVF runtime unmaps from
the hypervisor, replaces with fresh anonymous host backing, and maps again
before acknowledging the report. This releases macOS physical memory without
waiting for host pressure. See [memory reclamation](memory-reclamation.md) for
the constraints.

QEMU starts the edk2 firmware from a read-only pflash, with a 64 MiB
variable store per VM. The firmware loads Limine from the disk's ESP through
the removable-media path, and Limine boots the guest's own `linux-omarchy`
unified kernel image. The kernel and its command line belong to the guest:
`pacman` updates the kernel, Limine's hooks rebuild the image, and Snapper
snapshots appear in Limine's menu for rollback. Graphics travel from Linux through virtio-gpu and VirGL to the
native Cocoa window. The display selects native macOS OpenGL (`gl=on`), with
VirGL replaying commands in an Apple OpenGL 4.1 core context. Its local
multisample patch preserves real samples and mutable texture allocation,
allowing default browser ES 3 contexts without browser-specific overrides.
Native Apple drivers select integer vertex attributes automatically, and alpha
and BGRA texture paths avoid duplicate channel conversions. The kernel's text
console, where Omarchy's first-boot setup runs, reaches the host as 2D uploads
in VirGL's context 0. Apple GL shows one context's texture writes to another
only after a flush, so VirGL flushes context 0 after each upload. The guest runs
Omarchy's own aarch64 Hyprland package unpatched.
Storage, networking, audio, and input use their matching
QEMU virtual devices and host backends.

The guest starts at EL1 with QEMU's GICv3 by default. Nested virtualization
is opt-in (`OMARCHY_QEMU_GPU_NESTED_VIRT=1`) because the UEFI firmware also
runs at EL2, where its virtual-timer interrupt never arrives under HVF, so
Limine hangs in its first timer wait. When opted in on macOS 26 or newer, the
launcher first asks the bundled QEMU to create a tiny disposable HVF machine
with ARM virtualization extensions and Apple's platform GICv3. When that probe
succeeds on M3 and newer Apple Silicon, the real guest starts at EL2 and Linux
exposes `/dev/kvm`; otherwise the launcher keeps the EL1 configuration. The
launcher rejects hosts older than macOS 15 before probing or starting QEMU. The updated VirGL renderer is source-built for macOS 15.0,
including the dual-source shader fix used by accelerated terminals.
The pinned QEMU 11.1.1 runtime contains the upstream HVF vGIC and
nested-virtualization implementation.

Trackpad magnification uses a dedicated indirect virtio touchpad alongside the
ordinary pointer tablet. The Cocoa bridge reconstructs two contacts from each
pinch and releases them on cancellation or focus loss; the guest disables
tapping for this gesture-only device. See [pinch zoom](pinch-zoom.md) for the
input contract and integration validation.

## Host settings and the guest package

The launcher never writes the guest's kernel command line. It passes its
per-boot settings as the systemd credential `tryomarchy.host` over SMBIOS
type 11: one line of tokens such as `tryomarchy.keyboard=jis`,
`tryomarchy.locale=ja_JP.UTF-8`, `tryomarchy.timezone=Asia/Tokyo`,
`tryomarchy.ssh_access=1`, `omarchy.shared_folder_name=<base64url>` and the
VirGL flags. In the guest, `try-omarchy-host-config.service` publishes that
line at `/run/try-omarchy/cmdline`, which the package's units and scripts
read. systemd imports credentials natively and they have no length limit.

Everything Try Omarchy adds to the guest is the `try-omarchy` pacman package
([guest/package](../guest/package/README.md)). It installs under `/usr`,
uses systemd presets, drop-ins and udev rules, and adds one loader to the
user's Omarchy toggles directory for its Hyprland profile. It edits no file
another package owns.

The app also bundles the current package. On every boot it names the archive
in the `tryomarchy.package` credential and shares it on a read-only 9p share.
Before login, `try-omarchy-package-install.service` installs it with
`pacman -U` only when it is newer than the installed package (`vercmp`). A
guest that already has the same or a newer package keeps it. See
[integration updates](integration-updates.md).

The guest reports its versions back on `dev.tryomarchy.guest`: JSON lines
with the Omarchy and package versions, the channel, the running and installed
kernel, and the last package installation result. The bridge keeps the last
report in `shell/guest-status.json`, and the start menu's **Omarchy** row
shows it. The report is advisory. Either side ignores fields and ports it
does not know, so the app and the guest can be updated in either order.

Mac keyboard geometry (ANSI / ISO / JIS) is detected once per launch, given
to Cocoa, and passed as `tryomarchy.keyboard`. The package's Hyprland profile
sets the matching `kb_model=applealu_*`. See [Mac keyboard](mac-keyboard.md).

Omarchy's first-boot setup form offers **Same as macOS** first and preselects
it; it follows the Mac, and a separate root-only virtio port publishes live
zone changes. Choosing a named zone stops following, and **Same as macOS** in
Omarchy's timezone menu turns it back on. Internet clock synchronization
remains independent. See [Mac time zone and guest clock](host-timezone.md).

The macOS helper opens an authenticated connection to QEMU's private,
single-client machine protocol socket before host sleep and retains that control
session through wake. Before macOS sleeps it synchronously pauses the guest
vCPUs, and after wake it resumes them only when that sleep handler observed the
pause transition. The bundled Cocoa runtime removes its in-process Pause and
Resume menu actions because they cannot participate in QMP connection
ownership. Abnormal QEMU states such as an I/O error are never overridden. This
preserves in-memory guest state across lid close while leaving safety stops
untouched.

One small host-integration channel sits beside those devices. A virtio-serial
port (`dev.tryomarchy.clipboard`) carries newline-delimited JSON between a
Swift bridge on the Mac, which watches the `NSPasteboard` change count, and a
Python agent in the Omarchy session, which uses wl-clipboard's data-control
protocol. Text and PNG payloads flow both ways; each side remembers the
fingerprint of what it last wrote so the immediate echo is dropped. The marker
is cleared as soon as the other side moves on to new content, and expires after
a couple of seconds regardless, so a genuine repeat of the same content still flows.

A separate virtio-serial port (`dev.tryomarchy.camera`) carries fixed-size
1280×720 NV12 frames from an AVFoundation bridge in the signed Mac helper. The
guest feeds those frames into an exclusive-capabilities `v4l2loopback` device,
`/dev/video42`, labeled **Mac Camera**. The guest subscribes to the loopback
driver's client-usage events and requests capture only while a Linux application
is reading the camera. Camera permission, capture failure, or device removal is
non-fatal to the VM; the launcher can restart the optional bridge without
restarting Omarchy.

A further virtio-serial port (`dev.tryomarchy.battery`) mirrors the Mac's
battery into the guest. A Swift bridge watches IOKit power sources and sends
complete JSON snapshots — percentage, charge state, AC presence, time
estimates, charge limit, physical capacities, voltage, current, and cycle count —
on every change and every 30 seconds. A root guest agent writes
each snapshot as one line into a small DKMS `power_supply` module. DKMS builds
it against `linux-omarchy-headers` and rebuilds it for every kernel update. The
module presents `BAT0` and `ADP0` under `/sys/class/power_supply`, so UPower
and the Omarchy bar treat the VM as the laptop it runs on. The guest can only request
a refresh; nothing it sends can change Mac power state. A UPower drop-in keeps
the guest from acting on a critical battery — warnings appear, the Mac decides.
On a Mac with no internal battery the guest sees only mains power and the bar
shows nothing. See [host battery](host-battery.md) for the protocol and the
sysfs contract.

A root-only authentication port
(`dev.tryomarchy.authentication`) lets the guest's `sudo` PAM policy request a
fixed-purpose macOS Touch ID prompt. Enrollment creates a non-exportable P-256
signing key in the Mac's Secure Enclave for a root-private random guest ID and
pins its public key inside that guest. The host stores the Secure Enclave's
device-bound encrypted key representation outside the Keychain, so local ad-hoc
test builds do not need a provisioned Keychain access group. Each authentication uses a new 256-bit
challenge. The host signs a
canonical payload that binds the request ID, challenge, PAM user, requesting
user, `sudo` service, interactive TTY, guest ID, signing-key ID, and a 15-second validity
window. The guest verifies that signature with OpenSSL before PAM can return
success. It never accepts an unsigned approval boolean.

The integration's binaries and root-only device rule come with the package,
but the sudo PAM policy remains unchanged until the user opts in through the
**Touch ID for sudo** menu row the package adds. The root control enrolls first and
atomically adds the PAM rule only after successful guest-password and Touch ID
authentication. Disable removes that exact rule before deleting guest state and
requesting deletion of the corresponding host key representation. Re-pair runs
the disable and enable transitions while preserving password fallback.

The QEMU window must be frontmost, the QEMU process identity must still match,
and the host owns both enrollment and sudo prompt text. When enabled, the PAM
module is `sufficient`: a denial, missing enrollment, unavailable bridge,
invalid signature, non-interactive request, or timeout falls through to
Omarchy's normal password authentication. This integration does not authenticate
login or screen-unlock flows, cannot bind approval to the exact sudo command
because PAM does not expose it, and is not a general guest-to-host approval
service.

When a folder is chosen on the start menu, QEMU exports it over virtio-9p with
`security_model=none`, so every host file operation runs as the Mac user and
the Mac keeps real modes and ownership. A small QEMU patch adds
`guest_owner_uid`/`guest_owner_gid` fsdev options that report the Mac user's
files as the first Omarchy account (uid/gid 1000), which makes the guest
kernel's permission checks agree with what the host will actually allow. The
guest mounts the tag at `/mnt/mac` before the display manager starts, and a
user unit links `~/<folder name>` to it at login; the name travels in the
host credential as `omarchy.shared_folder_name=<base64url>`.

The personal share uses `cache=readahead`, which omits 9p writeback caching.
See [shared-folder safety](shared-folder-safety.md).

Optional port mappings are stored as a versioned launcher preference, validated
again at every Swift-to-shell boundary, and translated into QEMU user-network
`hostfwd` rules. The host side is always bound explicitly to `127.0.0.1`; the
launcher never creates wildcard or LAN-facing listeners. TCP and UDP occupy
separate host-port namespaces, matching QEMU's socket behavior.

**Add SSH** inserts an ordinary `tcp:2222:22` mapping into that same preference;
there is no second SSH forwarding store or QEMU argument path. After the shell
parser accepts the complete mapping list, any TCP rule targeting guest port 22
also adds the fixed `tryomarchy.ssh_access=1` host setting. UDP port 22 and
other guest ports do not. `try-omarchy-ssh-access.service` starts the vendor
`sshd.service` for that boot and allows port 22 through Omarchy's ufw
firewall from the NAT gateway (`10.0.2.2`), or from anywhere in bridged mode.
On boots without the setting it removes that rule. `sshd` is never enabled
persistently.

SSH host keys belong to the writable guest disk. A persistent VM keeps them;
Factory Reset and each ephemeral disk generate new keys. Reusing the same
Mac endpoint after either operation can require removing that endpoint from the
Mac's `known_hosts`. Loopback prevents LAN access but other local Mac processes
and users can still attempt authentication.

## The factory disk

The factory is built by this project from Omarchy's own repositories; it is
not an image published by Basecamp. `make guest` builds the `try-omarchy`
package, then installs the system in a privileged ARM64 Docker container the
way Omarchy's ISO installs a full disk: a GPT disk with a 2 GiB vfat ESP and
a btrfs root (`@`, `@home`, `@log`, `@pkg`), `pacstrap` of `linux-omarchy`
and the `omarchy-pkg-defaults aarch64` set, Limine, the image-target manifest
with `platform=aarch64`, and `omarchy-apply-system --defer-provisioning
--first-install`. Owner provisioning, hardware setup and the pacman keyring
are deferred to the VM's first boot, so the image holds no user, machine ID,
SSH host key or keyring. See [guest/factory](../guest/factory/README.md).

On ARM, Omarchy publishes only to the `edge` channel for now, and there it
installs `omarchy-dev` from the `quattro` branch, where the aarch64 platform
support lives. `factory.json` records the `[omarchy]` database digest the
build resolved against, and `packages.txt` records every installed version.

## What this project changes

- The Swift code is a separate macOS launcher and helper.
- A few QEMU C and Objective-C files are patched before QEMU is compiled. These
  patches cover the Cocoa app identity, display behavior, graphics integration,
  host audio-device routing, and shared-folder ownership mapping. Nested
  virtualization uses QEMU's upstream Apple HVF implementation unchanged.
- The edk2 firmware is extracted unchanged from the same pinned QEMU source
  archive (`macos/stage-uefi-firmware.sh`).
- Omarchy, its Hyprland stack and its kernel are stock packages. The guest
  adds the `try-omarchy` package and nothing else.
- New guests seed their locale once from the Mac's primary preferred language.
  The launcher maps English (and unsupported languages) to `en_US.UTF-8`,
  Traditional Chinese to `zh_TW.UTF-8`, Simplified Chinese to `zh_CN.UTF-8`,
  Korean to `ko_KR.UTF-8`, and Japanese to `ja_JP.UTF-8`. While Omarchy's
  owner provisioning is pending, `try-omarchy-locale` generates that locale
  and writes `LANG`. Later boots leave the guest's language alone, even if the
  Mac's language changes. Omarchy's setup chooses the input method; on a JIS
  Mac the package maps 英数/かな to input-method off/on. See
  [Japanese input](japanese-input.md).

## VM storage

Normal launches keep one VM under
`~/Library/Application Support/Try Omarchy/VM/v1` (or a chosen folder):

| Path | Contents |
| --- | --- |
| `shell/disk.img` | The VM's disk, an APFS clone of the factory disk |
| `shell/efi-vars.fd` | The VM's UEFI variable store |
| `shell/vm.json` | The factory identity the VM was created from |
| `shell/lock` | The launcher's lock, held for as long as QEMU runs |
| `shell/console.log` | The guest's virtio console, with the previous boot in `console.log.1` |
| `shell/guest-status.json` | The guest's last status report |
| `shell-factory/<sha256>.img` | The decompressed factory disk, kept once per factory |
| `shell-factory/<sha256>.img.zst` | A release app's downloaded factory image (`.download` while incomplete), removed once the VM has started |
| `network-identities/` | The bridged-mode MAC address |

Development builds carry the compressed factory in `Resources/guest/`.
Release builds carry `Resources/guest/download.json` instead: the compressed
image is over GitHub's 2 GiB release-asset limit and only a new VM needs it,
so it is published beside the DMG in 1 GiB parts. Before a launch that creates
a VM without a decompressed factory to clone, the app downloads the parts into
one `shell-factory/<sha256>.img.zst.download` file with HTTP range requests
that start where the file ends, checks each part's SHA-256 digest (including
parts already on disk when a download resumes), checks the whole image's
digest, and renames the file into place. It passes the result to the launcher
as `OMARCHY_QEMU_GPU_FACTORY_IMAGE`. Lost connections and server errors are
retried with backoff; a download stops before the volume has less than 1 GB
free. App instances share the download through a lock on `shell-factory/`.

On the first launch of a factory, the launcher verifies the compressed disk's
digest, decompresses it into `shell-factory/`, and returns its zero blocks to
APFS (about 9 GB stays allocated for the 20 GiB disk). Each new VM is then an
APFS clone of that file, so creating or resetting a VM costs no space. A
disposable session clones the same file into its own temporary folder.

The factory disk applies only when no VM exists, after a confirmed reset, or
in ephemeral mode. An app update never replaces an existing VM's disk; the
guest updates itself. Disks from earlier direct-boot versions of the app
(`disks/`, `boot/`) are left untouched and are not launched; the old root is
attached read-only so `try-omarchy-import-previous` in the guest can copy the
user's files.

Resources set the virtual disk capacity, 64 GiB by default. The launcher
grows the disk file sparsely and never shrinks it;
`try-omarchy-grow-root.service` grows the root partition and btrfs to fill
the disk at boot. APFS allocates blocks as guest writes arrive, so the
capacity does not reserve host space.

The workspace does not have to live in Application Support. The start menu can
put it in any folder the user picks, including one on an external drive, and the
launcher receives that choice as `OMARCHY_QEMU_GPU_STATE_ROOT`. The chosen
folder is used as-is: it is never restructured with a folder created inside
it, so it must already be empty (or already be a workspace Omarchy has used)
— a populated folder or a drive's top level is refused with an explanation
instead. The volume must be APFS: the launcher clones the factory disk with
`cp -c`, grows the VM disk sparsely, and serializes launches with a `lockf`
advisory lock. On exFAT the same growth allocates the full working size
immediately, and on a network share the lock is unreliable. Both layers check
independently, the app when the folder is chosen and the launcher again at
launch, because the volume can change in between. The **Selected VM → Manage** sheet separates
switching to an existing VM, moving the selected VM, and choosing an empty
folder for a new VM. Choices apply to the next launch; Done returns to the
launcher. Moving runs a separate native helper that takes the launcher's lock on
`shell/lock`, clones or sparsely copies the workspace to a private staging
sibling (without `shell-factory/`, which the launcher rebuilds), hashes every
regular file, checks for source and destination changes,
flushes files and directories, and atomically publishes the copy. Only success
changes the saved boot location. Phase and measured verification progress
stream to the management sheet, which stays open until the transaction ends.
The original is retained as a recovery copy;
unrecognized host files are never replaced. The lock file is recreated rather
than opened for copying, because closing any descriptor for a locked inode
would release the helper process's POSIX lock.

Deletion runs a separate `--trash-vm` helper process. Confirmation captures the
selected folder and disk identity. The helper validates the workspace, holds the
launcher lock, rejects a changed disk or unsafe tree, and moves the complete
folder to macOS Trash. Preferences and other VM copies are kept; failures never
fall back to permanent removal.

## Build layout

- `guest/` builds the `try-omarchy` package and the unprovisioned factory disk
  in a privileged ARM64 Docker container.
- `macos/` builds the Swift launcher, a patched QEMU runtime, and stages the
  edk2 firmware. The runtime is isolated, relocated, and signed before it
  enters the app bundle.
- `dist/` is the only public output directory. It is generated and ignored by
  Git.

## Trust model

The launcher validates the bundled `factory.json`, the compressed disk's
SHA-256 digest before decompressing it, the decompressed size, the bundled
firmware, and the app's code signature and required QEMU features. Host
settings reach the guest only as the two credentials; a stray environment
value cannot add QEMU options or export an unsafe folder.

App releases and guest updates are separate channels. Omarchy's own updater
moves the guest, kernel included, on the channel the user picks. The app can
only offer its bundled `try-omarchy` package, which the guest installs when it
is newer. Guest reports are advisory and cannot select host paths or run host
code. Factory reset is the way to start again from the current factory.

The factory build resolves against live repositories. The Omarchy repository
key in `guest/keys/` is reviewed and imported without a keyserver lookup;
package signatures remain required.

### Guest display synchronization

QEMU publishes the Cocoa window's current backing-pixel dimensions through
Virtio GPU EDID. The guest's `omarchy-native-display-sync` helper applies those
live timings at startup and on DRM hotplug events. The package's Hyprland
profile also invokes the helper with `--once` after `config.reloaded`: a configuration
reload can restore a cached preferred mode without emitting a hotplug event,
leaving the rendered desktop and absolute pointer coordinates out of sync.

Both paths reread Omarchy's numeric `omarchy_monitor_scale` setting from
`~/.config/hypr/monitors.lua` (under `$XDG_CONFIG_HOME` when set). An automatic or
absent setting uses the live EDID's pixel density. If a resized display cannot
represent the requested zoom exactly, the helper selects the nearest supported
scale with integral logical dimensions. Explicit per-output monitor rules still
take precedence over the helper's catch-all rule.

On a MacBook with a camera notch, full screen covers the whole panel, the
strip beside the housing included, and the guest describes the housing to
Omarchy's bar through Omarchy's own `display-cutouts.json`, so the bar sits
beside the camera and windows start below it. See
[camera notch](camera-notch.md).
