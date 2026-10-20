# User guide

Everything the [README](../README.md) leaves out: the launcher, each setting and integration, data, updates and recovery.

## Launching

The first launch downloads the Omarchy image (about 3 GB) from the same GitHub
release before it creates the VM; the launch button shows its progress. An
interrupted download, from a lost connection, sleep or quitting the app,
continues where it stopped on the next launch, and every part is checked
against its SHA-256 digest before it is used. The volume needs room for the
image and the prepared disk (about 15 GB); the download stops with 1 GB still
free rather than filling the disk.

By default, every launch begins at the launcher. Enable **Skip launcher** to start Omarchy using your saved settings on subsequent launches. A confirmation explains how to return to the launcher; choose **OK** to enable **Skip launcher** or **Cancel** to leave it off. Hold **Option** while opening the app to show the launcher again and change settings or turn **Skip launcher** off. You can also open **Setup → Try Omarchy Settings** inside Omarchy. Skip launcher is saved with the VM workspace; deleting that workspace clears the choice. A missing VM disk always shows the launcher, even if its settings file remains. Reset requests still open **Manage VMs** to confirm deleting the VM. Startup checks still show any error dialogs.

While that menu is open, Try Omarchy behaves like a regular Mac app. **Try Omarchy → Settings…** (**Command-comma**) brings the launcher or its open editor forward without discarding drafts. The menus also provide standard text editing, Services, Hide Others, Show All, and window commands, including Bring All to Front. **Help** opens the user guide, maintenance and recovery notes, or the issue tracker in your browser. After the VM starts, that native app chrome steps aside for Omarchy. **Immersive** is on by default, so Omarchy opens Full Screen with the Mac menu bar and Dock hidden. Turn it off to open a resizable window; if you later enter Full Screen, the Mac menu bar and Dock remain available at the screen edges. Whenever the Omarchy window is focused, Command belongs to the guest as Super in either mode; Accessibility permission lets system shortcuts such as Command-Space reach it before macOS. Microphone and camera access are optional. The first launch takes longer while the app prepares Linux and starts Omarchy's account provisioning.

Inside Omarchy, choose **Setup → Try Omarchy Settings**, search for **Try Omarchy Settings**, or run `omarchy-native-settings` to reopen the Mac settings window. You can change **Skip launcher**, permissions, CPU, memory, sharing, port forwarding, and immersive mode here. CPU, memory, sharing, ports, and immersive mode are saved for the next launch; **Restart Omarchy** shuts down Linux and starts a new VM process to apply them. Save your work first. A disposable VM keeps its disk across this restart until you close the app.

To move, switch, or delete the VM, choose **Shut Down**. The settings window stays open even with **Skip launcher** enabled; deleting still asks for confirmation. **Done** or closing the running settings window returns to Omarchy without stopping it.

Restarting from inside Omarchy reboots the guest in the same Try Omarchy app.
Shutting down Omarchy closes the app and leaves it closed.

## Virtual machine resources

Choose **Resources → Configure…** on the launcher’s **Home** or **Virtual Machine** pane to adjust processor cores
and memory, and set a maximum disk size for the next launch. Processor cores range from 4 to all the cores
on this Mac; the default remains up to 8 cores. Memory defaults to 8 GiB on
Macs with at least 16 GiB of RAM, and 4 GiB on smaller Macs. Custom allocations
can leave as little as 4 GiB for macOS; higher choices carry a performance note.

**Maximum disk size (GiB)** defaults to **64 GiB** for new launcher settings,
and supports capacities up to 8192 GiB.
Mac storage is allocated as the guest writes data, rather than reserving the
whole maximum in advance. For example, choosing 256 GiB does not immediately
use 256 GiB on the Mac. The volume still needs free space as the VM fills it;
the maximum is guest capacity, not a quota on backups or total app storage.

Keep the displayed value to retain the current capacity. Larger values sparsely
extend the stopped disk at the next launch; the guest grows its root partition
and btrfs filesystem on boot. Existing disks cannot shrink. **Use Defaults**
selects 64 GiB, or the existing capacity if larger. Previously saved settings
without a disk maximum retain their current capacity. For direct launcher
script usage, set `OMARCHY_QEMU_GPU_DISK_GIB=256`.

**Save** remembers these choices. **Cancel** leaves them unchanged, and
**Use Defaults** restores the draft until you save. Existing memory preferences
are carried forward. A choice that no longer fits a smaller Mac falls back to
its default without erasing the saved choice.

## Ghostty and 1Password

Both are ordinary Omarchy packages on ARM: install them from the Omarchy menu
(**Install → Terminal → Ghostty**, **Install → Service → 1Password**). Try
Omarchy no longer ships its own installers for them. Ghostty runs on the
software renderer because the VM's graphics path lacks the OpenGL version it
needs; see [Ghostty](ghostty.md).

## Camera sharing

Choose **Allow…** next to **Camera access** on the start menu to make the Mac's
FaceTime HD camera available in Omarchy as **Mac Camera**. The bridge publishes a
standard Linux V4L2 camera at `/dev/video42`, so browser calls and Linux camera
apps can use it without special configuration. Capture is on demand: the Mac
camera and its indicator turn on only while an Omarchy app is actively using
the virtual camera. Denying camera permission does not prevent Omarchy from
launching.

## Clipboard sharing

Copy and paste work in both directions as soon as you sign in to Omarchy: text
and PNG images copied on the Mac appear in the Omarchy clipboard, and content
copied in Omarchy lands on the Mac pasteboard. Nothing is transferred until
something is copied.

## Sharing a folder with the Mac

Folder sharing is off until you pick a folder. Use **Choose…** next to
**Shared Folder** in the launcher’s **Sharing** pane to select one Mac folder; Omarchy links it
into its home under the same name (`~/Work` on the Mac becomes `~/Work` in
Omarchy) with full read and write access, so choose a folder you intend Linux
software to modify. The whole home folder, `~/Library`, and system directories
cannot be shared. Turning its switch off keeps the choice but stops exporting it on the
next launch; Omarchy then removes the link and gives back any standard folder
such as `~/Documents` that the link had taken over. The share belongs to the
first Omarchy account created during
provisioning. Additional guest accounts can reach the same share, with each
entry's normal Unix permission bits deciding whether they can modify it.

The share uses `cache=readahead` to avoid the 9p writeback corruption risk in
some guest kernels. Writable shared memory mappings are unavailable; keep
databases and mmap-based IPC files on the guest's local disk. See
[shared-folder safety](shared-folder-safety.md) for the mount policy and
how to verify it.

## Passing a USB device to Omarchy (experimental)

Passthrough is off until you pick a device. Use **Choose…** next to **USB
Device** in the launcher’s **Sharing** pane to select one device currently attached to the Mac;
the choice applies on the next launch, and its switch turns passthrough on or off
without reselecting. Omarchy gets a USB 3 controller with that one device
attached, matched on its vendor and product identifiers and its physical bus
and port. The picker lists the bus and port for each device. The match stays
fixed even when only one device is connected, so unplugging it cannot hand an
identical device on another port to the guest. Moving a device to another port
requires choosing it again. If the saved device is absent at launch, Omarchy
starts without USB passthrough. Old selections without a saved location must
also be chosen again.

Upstream QEMU treats `hostbus=0` as "any bus", and libusb numbers the first
USB controller 0 — on a Mac with a dock, usually the controller behind every
dock and hub port. The bundled QEMU carries
`macos/patches/qemu-usb-host-exact-bus.patch` so that `hostbus=0` selects bus 0
exactly, and the launcher refuses a runtime without it. The selection
identifies a model at a physical port, not a serial number; replacing it with
the same model at the same port still matches.

Only one device at a time, and never a USB hub — passing a hub through would
take every device behind it, frequently this Mac's own dock, keyboard, or
display controls.

**What gets through depends entirely on privilege.** libusb's Darwin backend
accepts exactly two kinds of caller for taking a device away from macOS -- a
process holding `com.apple.vm.device-access`, or one running as root -- and
turns every other caller away before it asks the kernel anything:

```c
/* libusb/os/darwin_usb.c, darwin_detach_kernel_driver() */
if (0 != geteuid()) {
  usbi_warn (ctx, "USB device capture requires either an entitlement "
                  "(com.apple.vm.device-access) or root privilege");
  return LIBUSB_ERROR_ACCESS;
}
```

**Unprivileged, which is how this app ships:** only a device no macOS driver
has claimed, which is rarer than it sounds. Surveying every USB device attached
to one Apple Silicon Mac found a driver bound to all of them: hubs, docks
(through `AppleUSBHostBillboardDevice`), HID receivers, audio interfaces, USB
Ethernet and mass storage. What is left is hardware macOS has no driver for at
all, such as SDR receivers, JTAG probes and custom vendor-specific boards.
Everything else enumerates in the guest but never gets a configuration: `lsusb`
lists it while `/sys/bus/usb/devices/*/bConfigurationValue` stays empty, and no
`sda`, input device or camera appears. Both `libusb_detach_kernel_driver` and
`libusb_claim_interface` return `LIBUSB_ERROR_ACCESS` immediately, without the
kernel ever being asked.

**As root, this same build takes a driver-claimed device completely.** Measured
on one Apple Silicon Mac with a SanDisk 3.2Gen1 stick, a device class macOS
drives through `IOUSBMassStorageDriver`:

```
# inside the guest
$ lsblk
sda      57.3G disk
|-sda1     200M part vfat  EFI
`-sda2      57G part vfat  VCAUSB  /run/media/vcanuel/VCAUSB
$ cat /sys/bus/usb/devices/2-1/speed
5000
$ readlink /sys/bus/usb/devices/2-1:1.0/driver
../../../../../../../../bus/usb/drivers/usb-storage
$ dd if=/dev/urandom of=/run/media/vcanuel/VCAUSB/u.bin bs=1M count=256 conv=fsync
268435456 bytes (268 MB, 256 MiB) copied, 3.69127 s, 72.7 MB/s
```

The volume mounts on the Omarchy desktop like any other drive, and writes land
on the stick at SuperSpeed. Nothing in the passthrough path itself needs
changing for this; only the privilege of the process that calls libusb.

The xHCI controller is started with `streams=off`, so the guest uses
`usb-storage` rather than `uas`. With streams on, `uas` binds the same stick
but the first command after each connection gets no answer: after a replug,
`REPORT LUNS` and then `INQUIRY` each timed out after 30 s and forced a device
reset, so the stick mounted only about 60 s later. `usb-storage` on the same
stick reads its capacity about 1.2 s after connection, with no timeout. Linux
only picks `uas` on a controller that advertises streams, so with them off it
falls back to `usb-storage` by itself, with no guest configuration.

Unmount a drive on the Mac with `diskutil unmountDisk` rather than Finder's
**Eject** before handing it over. Eject sends the stick a SCSI stop, and it then
reports no medium (`[sda] Media removed`) until it is physically replugged.

Neither door is free. `com.apple.vm.device-access` is restricted: Apple grants
it per developer team, delivers it in a provisioning profile, and DTS describes
it as meant for virtualization apps shipping on the Mac App Store. Commercial
virtualization apps carry it, which is why they take a USB drive without
running as root. Root is not something a desktop app should assume either --
libusb reads the effective uid of the calling process, so it would be QEMU
itself running as root, not a small privileged helper alongside it. Which door
to open is a decision for whoever ships the app. See libusb/libusb#1014.

**Replugging can freeze the window, and a bad exit wedges the device.** Every
capture attempt goes through libusb's `darwin_reenumerate_device()`, which polls
an atomic for up to `DARWIN_REENUMERATE_TIMEOUT_US` — 10 seconds — on whichever
thread called it, and QEMU calls it from the main loop. Unplugging and
reconnecting the device while the VM runs costs one such timeout per attempt:
measured on this build, a QEMU-side detach blocked the main loop for 10.08 s,
and one physical replug stalled the guest's USB enumeration for 29.8 s (guest
kernel timestamps 34.98 → 64.77). The guest keeps computing, but the window
stops redrawing and stops accepting input until the timeout expires.

A later retest as root with `streams=off` did not reproduce the freeze: the
same stick, unmounted in the guest, then unplugged and replugged on the same
port, came back and remounted within about 5 s, with the window responsive
throughout. When the timeout is actually hit is not yet pinned down.

A device left behind by an unclean exit stays unusable until it is physically
reconnected. After QEMU was killed mid-reset, every bulk transfer to the stick
timed out — from QEMU and from a plain libusb program alike, both running as
root, with `libusb_claim_interface` still reporting success. One unplug and
replug restored it, and the same program then completed a SCSI INQUIRY in 20 ms.
Leave the device plugged in for the life of the VM, and replug it if a run ends
badly.

The guest needs its own tools for anything beyond enumeration: `usbutils` for
`lsusb`, `libimobiledevice` for an iPhone.

For scripted launches, `OMARCHY_QEMU_GPU_USB_HOST` overrides the saved choice
with a raw `usb-host` property list — `vendorid=0x05ac`, or
`hostbus=1,hostaddr=6` to pin one physical port. The start menu shows when the
environment owns the choice and leaves its buttons disabled.

## Networking

Use **Configure…** next to **Network** in the launcher’s **Network** pane. **NAT** shares the
Mac's connection and is the default. **Bridged** gives the VM its own LAN
address through a selected eligible Mac interface. Changes take effect on the
next launch. Bridging uses a networking helper approved once through macOS
System Settings. Use **Set Up / Repair Networking…** to register it; subsequent
bridged launches do not request your password. QEMU continues to run as your
user. **Remove Networking Helper** unregisters the service when it is no longer
needed. Shut down any bridged VM before repairing or removing the helper.

Persistent VMs keep a stable, randomly generated bridged MAC address across app
updates, disk replacement, resizing, resets, and moves of the complete VM data
folder. Existing saved addresses are retained when upgrading from older builds.
The Networking sheet displays the address after the first bridged launch;
**Copy MAC** makes it available for a DHCP reservation. **Generate new MAC…**
shows a proposed address and requires confirmation while the VM is stopped.
This action saves immediately; DHCP reservations may need updating. Cancelling
the confirmation leaves the existing identity unchanged.

A copy of the complete VM data folder includes its network identity. To run a
copy as a separate VM, generate a new MAC before running both copies. Move or
restore the complete data folder to retain the identity; importing only a disk
into a new workspace does not transfer its network identity. Ephemeral bridged
VMs receive a fresh address on each launch. Damaged identity records produce an
error instead of silently changing the MAC. Regeneration retains
the preceding record as `network-identities/current.previous.json` in the VM
data folder; restore a known-good record only with the VM stopped.

For repeated local development builds, use a consistent Apple Development
signing identity (the `DEVELOPMENT_SIGN_IDENTITY` option above). Ad-hoc-signed
helper registrations are not reliable across rebuilds on the tested macOS
version. Approval is checked separately from a working helper connection;
repair and launch verify that the helper belongs to the current app copy.

On Wi-Fi hosts that expose the compatibility control, selecting bridging
automatically enables temporary host-wide DHCP handling. The networking sheet
explains this before you save the choice. It can affect other virtualization
apps while the bridged VM runs. The previous setting is restored when the VM stops, the
app exits, or the bridge helper fails. If the privileged supervisor itself is
forcibly killed, restoration is retried on the next bridged launch. There is no
separate compatibility checkbox. NAT does not change this host setting.

Saved port-forwarding rules remain stored but are inactive in bridged mode.
Services listening on the guest network interface can be reached directly from
the LAN. **Allow SSH connections from the LAN** is a separate opt-in; switching
from a NAT SSH mapping does not enable it automatically. Guest account setup
and SSH authentication are still required. Only one bridged Try Omarchy session
can run at a time on a Mac.

If the selected adapter is unplugged, Omarchy starts offline and connects when
it returns. Unplugging and reconnecting the adapter while running also recovers
without restarting the VM. The selected adapter is preserved; the app does not
automatically switch to NAT or another interface.

## Forwarding ports to Omarchy

In NAT mode, use **Configure…** next to **Port Forwarding** in the launcher’s **Network** pane to map a Mac
localhost port to a service port in Omarchy. Each mapping can use TCP or UDP;
the same Mac port may be used once for each protocol. Forwarded ports bind only
to `127.0.0.1`, so other devices on the network cannot connect to them. The
service inside Omarchy must listen on `0.0.0.0` or the guest network interface,
not only on the guest's own localhost.

The reverse direction does not need a mapping. From Omarchy, connect to
`10.0.2.2:<Mac port>` to reach a service running on the Mac.

### SSH access

After completing Omarchy's first-boot account setup, open **Port forwarding**,
choose **Add SSH**, and save the prefilled TCP mapping from Mac port `2222` to
Omarchy port `22`. Try Omarchy then starts `sshd` for boots that contain a TCP
mapping to guest port 22, and allows port 22 through Omarchy's firewall from
the Mac's NAT gateway for those boots. It does not change guest accounts,
`sshd_config`, password policy, or authorized keys.

Connect with the username and password created inside Omarchy (the Mac username
is not assumed):

```sh
ssh -p 2222 <guest-user>@127.0.0.1
```

Once the initial password login works, install a key if desired:

```sh
ssh-copy-id -p 2222 <guest-user>@127.0.0.1
```

For a shorter command, add this to `~/.ssh/config` on the Mac:

```sshconfig
Host omarchy
  HostName 127.0.0.1
  Port 2222
  User <guest-user>
```

You can then use `ssh omarchy`, and the same alias works with `scp`, `rsync`,
Git, and VS Code Remote SSH. If you edit the preset's Mac port, substitute that
port in every command.

A fresh VM after deletion creates a new guest host key, and every ephemeral VM has its own
disposable host key. If OpenSSH reports that the key for the reused endpoint
changed, remove only that endpoint's old entry and reconnect to verify the new
fingerprint:

```sh
ssh-keygen -R '[127.0.0.1]:2222'
```

Loopback binding prevents devices on Wi-Fi, Ethernet, or the wider LAN from
connecting. It does not isolate the listener from other users or processes on
the same Mac; guest SSH authentication is still required.

### Touch ID for 1Password

An optional process-scoped integration can use the Mac's Touch ID to unlock
1Password inside the guest. Existing synced passwords and passkeys stay managed
by 1Password. See [setup and authorization boundaries](onepassword-touch-id.md).

### Touch ID for sudo

[Guest clock recovery](guest-clock-recovery.md) handles time lost during
Mac sleep so fresh signed approvals remain usable after wake.

The native authentication bridge can enroll this Mac and use
Touch ID as a sufficient authentication method for guest `sudo`. Open
the **Touch ID for sudo** row in the Omarchy menu, or run:

```sh
try-omarchy-touch-id
```

The integration ships disabled. Enabling first requires the normal guest sudo
password, then Touch ID creates and proves possession of a Secure Enclave
signing key. Only after that succeeds is the narrowly scoped sudo PAM rule
installed. The menu then offers Test, Re-pair, and Disable actions.

The Mac stores only the Secure Enclave's device-bound encrypted key
representation. Every later approval is signed over a root-private guest ID,
fresh challenge, the sudo user and requesting user, the interactive TTY, and a
15-second validity window. Each enrolled guest has a distinct host signing key.
The QEMU window must be frontmost. Cancellation, invalid responses, missing
enrollment, and unavailable Touch ID all fall back to the normal guest password;
no login or screen-unlock PAM policy is changed.

If Touch ID falls back, sudo displays the reason before asking for the guest
password. Signed approvals require synchronized Mac and guest clocks. If the
guest clock drifted, run `sudo systemctl enable --now systemd-timesyncd.service`,
then check `timedatectl` for `System clock synchronized: yes` before retrying.
Touch ID has not been verified in the current guest yet.

The Touch ID test refuses guest-password fallback and returns failure if sudo
cannot authenticate. A passwordless sudo policy can also satisfy this check;
the result only demonstrates Touch ID when its prompt appeared. Unanswered Mac
prompts are canceled after 55 seconds, before the guest's 65-second timeout.
Late responses are discarded without extending the current request's deadline.

Enrollment persists across guest and Mac restarts for the same persistent VM,
Mac, and macOS account. Deleting the VM for a fresh one, moving the VM to another Mac or account,
or changing the enrolled Touch ID fingerprint set requires re-pairing. Disabling
removes the guest enrollment and, while the host bridge is available, its wrapped
Secure Enclave key representation.

## Giving Omarchy more memory

Use **Resources → Configure…** in the launcher to pick how much of the Mac's
RAM the guest boots with. Macs with at least 16 GiB default to 8 GiB; smaller
Macs default to 4 GiB. The menu offers 4, 6, 8, 12 GiB and then continues in
4 GiB steps, leaving at least 4 GiB for macOS. For example, a 16 GiB Mac can
allocate up to 12 GiB, and a 48 GiB Mac up to 44 GiB. Higher choices that leave less
than 8 GiB for macOS are marked “may slow macOS.” An 8 GiB Mac offers 4 GiB only.
Existing saved choices, including 4 GiB, are preserved. The choice is not tied to installation: change it
before any launch, and it applies the next time Omarchy starts. Memory is a
boot-time QEMU setting, never part of the guest image or VM data, so switching
allocations never needs a reset and never touches your files. A stored choice
that no longer fits the Mac it runs on falls back to the default.

Unused guest memory is automatically returned to macOS through virtio free-page
reporting. Omarchy still sees the full selected RAM and can use it again when
needed. Reclamation runs asynchronously and covers genuinely free pages, not
Linux's file cache or memory still held by applications. For example, selecting
16 GiB and seeing 12 GiB used does not guarantee exactly 4 GiB returned: cache,
fragmentation, and VM overhead also affect the Mac's memory usage. Keep enough
headroom for macOS even with reclamation enabled.

Scripted launches can set `OMARCHY_QEMU_GPU_MEMORY_MIB` (a whole number of
MiB) instead. Scripted launches use the same host-aware default and leave
at least 4 GiB for macOS for allocations above the 4 GiB baseline. They also
accept values between menu steps, down to the guest's 2048 MiB minimum. The
4 GiB baseline remains available on smaller hosts such as CI runners.

## Language

New VMs inherit the Mac's primary language on first boot: English, Traditional
Chinese (`zh_TW.UTF-8`), Simplified Chinese (`zh_CN.UTF-8`), Korean
(`ko_KR.UTF-8`), or Japanese (`ja_JP.UTF-8`). Other Mac languages currently fall
back to English. There is no launcher language setting; change the locale inside Omarchy afterward. Later
boots and Mac language changes do not overwrite that guest choice.

Applications use translations where available. Omarchy's own setup wizard and
menus stay in English: upstream has no translation mechanism for those shell
scripts.

### Japanese, Chinese and Korean input

Omarchy sets up input methods itself. Its first-boot form asks for the keyboard
and input method (choosing Japanese selects Mozc); change it later with
**Super+I** or **Setup > Input**. The `try-omarchy` package keeps the Mozc,
Chewing and Hangul engines and CJK fonts installed, and on a Mac JIS keyboard
maps **かな** and **英数** to turning the input method on and off. macOS and
Omarchy select their input methods independently. See
[Japanese input](japanese-input.md) for details and verification.

## Requirements

- Apple Silicon Mac (`arm64`)
- macOS 15 or newer
- About 12 GB free for the first launch (the decompressed factory disk is about
  9 GB), plus room for the VM to grow

Nested virtualization is off by default: with ARM EL2 exposed, the UEFI boot
currently hangs before Linux starts on M3 and newer Apple Silicon. Scripted
launches can set `OMARCHY_QEMU_GPU_NESTED_VIRT=1` to try it on macOS 26 or
newer; when the host supports EL2, the guest then provides `/dev/kvm` for
nested VMs and compatible VMMs. Hardware-accelerated graphics are available on
both macOS 15 and macOS 26.

## Data and updates

### Check for Mac app updates

The start menu shows the installed Mac app release and **Check for Updates…**;
the native application menu offers the same command. The update window checks
the project's latest stable GitHub release and links to its release notes and
download. Review the release's macOS requirements before installing.

**Automatically check for updates** is on by default; an existing choice to
disable it is preserved. Opening the app checks at most once every 24 hours.
A newer release changes the start menu link to **Update Available…** and shows
a **Download / Skip** dialog when the launcher or settings are ready. It waits
while you use the guest or another dialog. **Download** opens the GitHub release
page; **Skip** hides reminders for that version. Each release is announced only
once, and the update link and manual checks remain available at any time.
Checks contact GitHub without a GitHub account, and failures do not block VM
startup. This feature does not download or install app updates automatically.

Older app bundles used the same version metadata for different releases. If
the build does not include a matching release tag in its metadata, the window
reports an unknown installed release or a development build instead of claiming
that it is up to date. The latest release and manual download remain available.

To upgrade, shut down Omarchy, quit the app, download the new DMG, and replace
**Try Omarchy** in **Applications**. Reopen it to use your existing VM. You do
not need to reset or delete the VM to update the Mac app.

### Existing VM data

Normal launches keep one persistent VM under
`~/Library/Application Support/Try Omarchy/VM/v1`: its disk and UEFI variables
in `shell/`, and the decompressed factory disk, shared by every new VM, in
`shell-factory/`. Removing or updating the app does not remove or replace this
data. The VM boots its own kernel and updates itself. A newer app's factory
image is downloaded only to create a new VM, after the VM is deleted, or for
an ephemeral launch, and removed once the VM has started.

VMs created by earlier versions of the app, which booted a kernel from the Mac,
are not launched by this version. Their files (`disks/`, `boot/`) stay in the
same folder untouched, and the app attaches the old disk to the new VM
read-only. Omarchy says so once after login; to bring your files over, choose
**Setup > Import Previous VM** in the Omarchy menu, or run:

```sh
try-omarchy-import-previous --dry-run   # list what would be copied
try-omarchy-import-previous             # copy it
try-omarchy-import-previous --packages  # install the packages you had added
try-omarchy-import-previous --open      # browse the old disk, --close when done
```

The import copies every visible file and folder in your old home folder, plus
SSH and GnuPG keys, Git and GitHub CLI settings, fonts, `pass`, AWS and
Kubernetes credentials, and never replaces a file that already exists. It
leaves the old `~/.config` alone, since it was written for an older Omarchy;
browse it with `--open` and copy what you want by hand. `--packages` installs
the packages you installed yourself in the old VM; those not in Omarchy's
repositories (from the AUR, say) are listed for `yay`. When you have
everything, delete `disks/` and `boot/` from the storage folder to detach the
old disk and free its space. Deleting the VM leaves them alone.

### Guest console log

Each persistent launch writes the guest's virtio console to
`~/Library/Application Support/Try Omarchy/VM/v1/shell/console.log`, and moves
the previous launch's log aside to `console.log.1` first. The guest adds
`console=hvc0` to its own kernel command line for this. This is the record to
read when Omarchy fails to boot, loses its network, or hangs, because a fault
that forces a reboot is otherwise gone by the time you can look. An ephemeral
launch keeps its log with the rest of its temporary state and discards it on
exit. The log holds whatever the guest prints to its console, so treat it as
guest data and review it before attaching it to a bug report.

If QEMU crashes in `hv_vm_map` or `hv_vm_unmap`, a trace of the VM's memory
mappings shows which range failed. Quit Try Omarchy, then launch from Terminal
with an absolute log path:

```sh
OMARCHY_QEMU_GPU_HVF_TRACE_LOG="$HOME/Desktop/hvf-trace.log" \
  "/Applications/Try Omarchy.app/Contents/Resources/scripts/run-qemu-gpu.sh"
```

The log holds memory addresses and sizes, no guest data. Attach its last few
hundred lines with the crash report.

### Updating Omarchy

Omarchy updates itself inside the VM: run `omarchy update` or use
**Update → Omarchy** in the Omarchy menu. It updates Omarchy, Hyprland and the
kernel, and takes a Snapper snapshot first; the snapshot appears in the boot
menu so you can roll back. `omarchy-channel-set` switches channels when
Omarchy publishes another one for ARM. Updating the Mac app does not change
these.

To start again from the newest bundled factory, delete the VM in **Manage
VMs**; the next launch in the default folder prepares its replacement. Deleting
moves the VM to macOS Trash, so **Put Back** restores a mistake until you empty
Trash. **Virtual Machine → Reset Settings…** is separate: it returns resources,
networking, port forwarding, the shared folder, USB device, audio devices,
Immersive Mode, Camera Notch, and Skip Launcher to their defaults and leaves
the VM untouched.

### Updating integrations

The Mac integrations inside Omarchy are the `try-omarchy` package. Each app
release bundles its version and offers it to the VM at every boot; the VM
installs it before login when it is newer than the installed one. There is
nothing to approve or run. The start menu's **Omarchy** row shows the guest's
Omarchy version and channel, and the integration version, after the VM has
started once. See [integration updates](integration-updates.md).

### Choosing where the VM lives

Open **Manage…** on the **Selected VM** row of the launcher's **Virtual Machine** pane after shutting down
Omarchy. The dialog shows the selected VM folder and explains what the next
launch will do:

- **Switch to another VM → Choose Existing VM…** selects a saved VM in another
  folder. Choose the complete folder containing `shell`.
  Files stay where they are; this changes which VM the app will launch.
- **Move the selected VM → Choose Destination…** asks you to confirm, copies
  that VM into a completely empty APFS folder, verifies every file, and selects
  the copy only after success. Then the original moves to macOS Trash, where
  you can recover it until you empty Trash. The decompressed factory copy is
  not moved; the next launch rebuilds it. The dialog shows copy and
  verification progress, then the new selected folder.
- **Create a separate VM → Choose Empty Folder…** selects an empty folder for a
  fresh VM, created on the next launch. The previously selected VM is kept.
- **Delete the selected VM → Delete VM…** asks once, then moves the whole VM
  folder to macOS Trash; restore it with **Put Back**. In the default folder the
  next launch starts a fresh Omarchy; otherwise choose another VM or an empty
  folder to continue. A running VM cannot be deleted.
- **Use Default Folder** selects
  `~/Library/Application Support/Try Omarchy/VM/v1` again. If that VM has been
  deleted, the next launch creates a fresh VM there.

Choices are saved immediately. **Done** returns to the launcher; press
**Launch** there to start the selected VM. During copying, verification, or Trash,
**Done** and the other choices are disabled. Errors stay in the dialog. Failed operations keep the selected VM intact.

Moving always acts on the VM selected in the dialog. To move a different saved
VM, switch to it first. Copies evolve independently after booting; switch
between them with **Choose Existing VM…**.

For example, create `~/Try Omarchy` in the folder picker to relocate the VM
into your home directory. Omarchy uses exactly the selected folder. A drive's
top level and unrelated populated folders are refused.

Both locations must be on local **APFS** drives. Relocation holds the same
lock as the launcher, refuses an open VM and unsafe links, and never
replaces files at the destination. Same-volume copies use APFS clones;
cross-volume copies preserve sparse capacity. Leave enough free space for the
VM's allocated data plus 1 GiB of headroom. If copying or verification fails,
the original and the selected boot location stay unchanged. After a verified
move, only the original VM folder goes to Trash. For the default location that
is `VM/v1`; the surrounding `Try Omarchy` Application Support folder stays,
because it also stores the host Touch ID keys used by the relocated VM. Keep
the original in Trash until you have booted and checked the relocated VM.

- Do not disconnect the drive while Omarchy is running. macOS refuses a normal
  eject while the VM holds the disk, but pulling the cable can damage it. If the
  volume does disappear, Omarchy shuts the VM down instead of writing on.
- **If the drive is not connected, Omarchy will not quietly use the default VM
  instead.** Launching offers to switch back to the default folder; deleting
  refuses outright, so it can never trash a workspace other than the one you
  confirmed. Opening the folder from the start menu will not recreate it on
  your startup disk either.
