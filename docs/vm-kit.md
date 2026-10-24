# The VM kit and run mode

Another app can run the Omarchy VM without Try Omarchy's launcher window. Omarchy Installer does this for its Try mode ([one app plan](one-app.md)). It embeds three things from this repository's releases:

- **the kit:** `TryOmarchyKit.bundle`, the full app's helper and resources with its own bridged-networking daemon, which the embedding app registers, as a helper bundle with no identity of its own;
- **the run mode:** `omarchy-vm-helper --run-vm`, the kit's helper with no window;
- **the client:** `TryOmarchyKitClient`, a Swift library that starts the run mode and follows it.

## One session

The full app and the run mode run the VM through the same session (`VMRunSession`). The session downloads the image a new VM needs, starts the launch script, waits for QMP, pauses the VM across Mac sleep, stops it when its storage volume goes away, and reports the exit. Both read the same stored settings and serve the settings bridge. The full app keeps its start menu, VM moves and deletions.

## The kit

`make kit` builds a production app, ad-hoc signed, and derives the kit from it (`macos/build-kit.sh`) in `dist/kit.noindex/`. `make package` and `make release` build the kit from the release app, sign and notarize it ([releasing](releasing.md#the-kit)). `make publish` uploads `TryOmarchyKit.zip` and `TryOmarchyKit.zip.sha256` with the DMG and the image parts.

The kit carries the helper, the QEMU runtime, the firmware, the launch scripts, the `try-omarchy` package and the image's download manifest. It does not carry the image: its first start downloads the parts from the release the kit came from. Releases are never deleted, because installers pinned to an old kit need its parts.

CI builds a kit on macOS 15 and 26 from the runtime and a stand-in for the guest, and `make test-kit` checks it: the archive and its digest, the signature of every Mach-O, that the kit has no identity, QEMU starting with its libraries, `kit.json`, the bridged-networking runtime and its pins, the launcher's self-check, and the run mode of the kit's own helper. `make kit` runs the same check.

### Layout

`TryOmarchyKit.zip` holds one folder, `TryOmarchyKit.bundle`. An app unpacks it and finds, inside that folder:

- the helper at `Contents/MacOS/omarchy-vm-helper`, and the networking daemon beside it ([bridged networking](#bridged-networking));
- the manifest at `Contents/Resources/kit.json`;
- the runtime, firmware, scripts and guest files beside the manifest, in `Contents/Resources`.

The kit carries no updater: the app's Sparkle framework is left out, because the embedding app updates itself and the kit with it.

An embedding app keeps its kit in `Contents/Helpers/TryOmarchyKit.bundle`, and a kit it fetches in a folder of its own. The client follows the same paths: `TryOmarchyKit.embedded(in:)` for the kit in an app, `TryOmarchyKit.unpacked(in:)` for a folder that holds the unpacked zip, and `helperURL()` and `manifestURL` within either.

### No identity

The kit is a bundle, not an app. Its `Info.plist` names its executable, says it is a bundle, keeps it out of the Dock and asks for sharp text. It has no bundle identifier and no name. macOS files preferences, permission grants and Launch Services records under an app's identifier, so the kit never appears as an app of its own: not in the Dock, not in System Settings, not as an app Launch Services knows.

It stays a bundle, rather than loose files, for three reasons:

- the helper finds its resources through its bundle, as it does in the full app;
- the signature seals the bundle's scripts, firmware and guest files, so the launcher checks the whole kit before each start (`codesign --verify --deep --strict`);
- an app's signature treats a folder in `Contents/Helpers` as one nested piece of code only when it is a bundle with an extension; otherwise it expects every file there to be code.

macOS attributes a helper's permission requests to the app that started it, so it asks for Accessibility, Microphone and Camera in that app's name, with that app's usage descriptions, as long as the app starts the helper as its child. The few values the helper keeps in UserDefaults, such as the last notch measurement, go to the domain macOS names after its file, `omarchy-vm-helper`.

### Signatures

Every Mach-O in a kit, and the bundle, carry the code-signing identifier `dev.tryomarchy.kit`, which is not a bundle identifier, and one signer. A release kit is signed by this repository's team, `RZC79MPD34`, with the hardened runtime and a secure timestamp, and notarized. QEMU carries the hypervisor and microphone entitlements, the helper the camera and microphone, and the rest none. A kit from `make kit` or CI is signed ad hoc, without the hardened runtime, because the hardened runtime refuses libraries that have no team.

An app that embeds the kit re-signs every Mach-O in it as itself, except the networking server, supervisor and client, which the daemon pins ([what the embedding app does](#what-the-embedding-app-does)). An app that fetches a newer kit runs it as the release signed it. Either way macOS asks for Accessibility, Microphone and Camera in the app's name, because the app starts the kit.

## The kit's version

Every kit carries a manifest, `Contents/Resources/kit.json`, and each release also publishes it as `TryOmarchyKit.json`, so an app can read it before downloading the kit. `TryOmarchyKit.manifest()` in the client reads and validates it.

```json
{
  "format": 1,
  "version": "v1.2.3",
  "runProtocolVersion": 1,
  "buildDate": "2026-10-23T09:30:05Z"
}
```

- `version` is the release tag the kit was built from. A kit built from anything else, such as `make kit` on an untagged or modified commit, says `development`.
- `runProtocolVersion` is the run-mode protocol its helper speaks. A client runs only a kit with its own protocol version (`isSupported`).
- `buildDate` is when the kit was built, in UTC.
- Readers ignore keys they do not know. `format` changes only when a known key changes meaning.

Releases compare by their numbers (`TryOmarchyKitVersion`). A development kit compares newer than every release, so an app built with one keeps it rather than replacing it with a fetched kit. For that reason an installer refuses a fetched kit whose version is `development`, and an installer's release build refuses to embed one; `TryOmarchyKitVersion.isDevelopment` checks it. An app never runs a kit older than the one it embeds. A kit without a manifest predates it, so it is older than any kit that has one.

`make release` checks that the kit's manifest names the release's tag.

## The run mode

The app starts `omarchy-vm-helper --run-vm` from the kit, writes one configuration line to its standard input, and reads one event per line from its standard output. Diagnostics go to standard error. The protocol and its validation are in `macos/Sources/TryOmarchyKitClient/VMRunProtocol.swift`.

The configuration names the product, its icon (an `.icns` or `.png` file; the kit's own icon when absent), the optional bridges and the VM's folder. Its memory, CPUs and network are fallbacks for a VM with no stored settings ([settings](#settings)). `network` is `shared` or `bridged`; any other value, or none, fails with `invalid-configuration`. Audio, guest status and the settings bridge always run.

The Omarchy window, its Dock entry and its application menu carry the product's name and icon. The Dock names a process that has no app bundle after its file, even when it starts through a link. So the launcher starts QEMU from a minimal app bundle named after the product, in the run's private folder, whose executable links to the signed binary. That bundle has no identifier either, so Launch Services never records a second app, and the run's permissions stay with the app that started it. The binary stays in place, so its signature and the bridges' check of the QEMU process, which reads the path of the running file, are unchanged. A name that cannot be a file name, with a `/` or longer than 251 bytes, keeps the binary's name in the Dock.

The run mode writes `progress` (a phase and a percent), `notice` (a stable code and a message, while Omarchy starts anyway), `ready`, `stopping`, `error` (a stable code and a message) and, last, `exited`. Codes do not change between versions; messages may. A reader skips an event, or a notice code, it does not know, so a newer kit can add them. Clients from before `notice` treat it as a protocol error; none was released.

`make test` starts the run mode as a real process (`macos/Tests/run-mode.test.sh`), with a kit whose launcher serves QMP but runs no VM and a factory served on the loopback interface. `OMARCHY_VM_RUN_TEST_SKIP_PREFLIGHT=1` lets it run on CI runners without a hypervisor; `VMRunClient` never passes it on.

The run mode shuts down when it reads the `shutdown` command, when its input closes, or on a first signal. It asks Omarchy to shut down over QMP, waits up to a minute, then stops QEMU. So an app that crashes or is force-quit still shuts Omarchy down. A second signal stops QEMU at once, even when both arrive together.

The client has both. `shutDown()` sends the command. `terminate()` stops the VM at once, as pulling the power would: it sends two signals, and kills a helper that is still running five seconds later, after asking its launcher to stop QEMU.

The image download pauses on cellular and Low Data Mode connections and keeps the Mac awake.

## Settings

The run mode boots the VM in the folder its configuration names, and starts it with the settings the launcher window stored for that VM. It uses the configuration only for what was never stored:

- **the VM folder:** the configuration's `storageRoot`. The run mode then ignores the folder chosen in the launcher, so a VM moved in Try Omarchy, or a choice that cannot be read, never changes which VM it boots. Without a `storageRoot`, it is the folder chosen in the launcher, else the default folder; a chosen folder that is missing, or a choice that cannot be read, stops the run with `storage-unavailable`, and it never falls back to another VM.
- **memory and CPUs** (and the disk's maximum size): the stored resources, then the configuration's `memoryMiB` and `cpus`, then the launcher's automatic choice.
- **networking:** the stored mode, then the configuration's `network`. Bridged networking from the configuration uses the first interface the Networking settings list, which they select until someone picks one; a Mac with none fails with `bridged-network-unavailable`. When bridged networking cannot start ([bridged networking](#bridged-networking)), a configuration that asks for it fails with `bridged-network-unavailable`, and a stored bridged choice starts with shared networking and a notice instead, so Try is never stuck.
- **port forwarding, the shared folder, the USB device, Immersive Mode and the camera notch:** stored only. A port that is in use fails with `launch-failed`.

Audio follows the Mac's default devices. The development overrides (`OMARCHY_QEMU_GPU_STATE_ROOT`, `OMARCHY_QEMU_GPU_PORT_FORWARDS` and the like) still win, and `VMRunClient` never passes them on.

Choosing Try Omarchy Settings in Omarchy's Setup menu opens the launcher's window from the run mode's process, named after the product. Like the full app's settings while Omarchy runs, it is an accessory window: it comes to the front with the keyboard, and the process never appears in the Dock or the menu bar. The process takes the configuration's icon, and its About panel names the product, so no system UI shows the kit. The window has the full app's sharing, network, virtual machine and Immersive Mode settings, and the permission rows, which ask macOS in the embedding app's name. It has no launch, restart, shut down, Skip Launcher or update check: the embedding app owns those. Changes apply at the next start. Quitting from the window shuts Omarchy down, like the `shutdown` command.

Settings are stored in files, not in an app's preferences, so any kit reads the same ones whichever app it runs under:

- `settings.json` in the VM's folder, beside `launcher-settings.json`, holds the VM's settings. It moves and is deleted with the VM.
- `storage-location.json` in `~/Library/Application Support/Try Omarchy` holds which folder is the VM.

Both are private (0600) from their first byte and versioned, and saves lock the folder, so the full app and the run mode never lose each other's changes. A file that is not private, is too large or comes from a newer schema is ignored and never overwritten; for `storage-location.json` that stops the launch instead of using the default folder. A file is a JSON object with `schemaVersion` and `settings`. A save keeps every key it does not know, at the top level and in `settings`, so keys a newer kit adds survive an older kit's save. A setting that was reset is stored as `null`.

Older versions of the full app, up to Try Omarchy 1.2, keep these settings in its UserDefaults (`dev.tryomarchy.native`), and keep changing them there. One rule decides each setting, in both files:

- A key in the file wins, even as `null`, which is a setting that was reset.
- Without the key, the value in those UserDefaults applies.

So the files and the UserDefaults never disagree about who wins, whichever app reads them:

- The run mode reads those UserDefaults at every start and never changes them. It follows a change made in 1.2, such as memory, a VM move or **Use default**, until the file has that key.
- The run mode's own saves, from its settings window, write only the keys they save. They win over 1.2 from then on.
- The run mode never writes `storage-location.json`. When its configuration names no folder, it follows the VM folder chosen in 1.2 until the full app moves that choice.
- Only the full app, which owns those UserDefaults, moves values. When it opens the VM it copies each value the file lacks into the file, and removes from its UserDefaults every value the file has. No setting changes when it does, and from then on the files are the only source.

A folder the configuration names takes them, like any other. A VM folder set by `OMARCHY_QEMU_GPU_STATE_ROOT` never takes them.

### Finding the VM

The full app can move the VM to another folder or drive. An embedding app does not follow it there: it names the default folder, `TryOmarchyStorage.defaultRoot()`, as the configuration's `storageRoot`, and the run mode boots that folder.

An embedding app uses the same folder for whether a VM exists (`hasVM(at:)`), the free space it needs (`requiredFreeBytes(at:)` and `freeBytes(at:)`) and the space it takes (`allocatedBytes(at:)`). It deletes only that folder. A VM the full app moved elsewhere is not the one the embedding app boots, and is the full app's to move or delete.

## Bridged networking

Bridged networking needs a launch daemon that runs as root. Only the app whose bundle holds the daemon's job can register it with Service Management, and macOS lists it under that app's name in Login Items. So the kit carries its daemon, and the embedding app registers it as itself. The run mode never registers anything.

The kit's networking runtime:

- `Contents/MacOS/omarchy-network-daemon`, beside the helper;
- the server (`socket_vmnet`), the supervisor and the client, in `Contents/Resources/network`;
- the daemon's job, `Contents/Resources/network/launchd.plist`, whose label and Mach service are `dev.tryomarchy.kit.network` and whose `BundleProgram` names the daemon relative to the kit.

The service is the kit's own, so it never collides with the full app's `dev.tryomarchy.network`, and both can be set up on one Mac.

The daemon trusts bytes, not teams. It is built after the client and the payloads are signed, and pins the client's code-signing hash and the payloads' SHA-256. It accepts XPC connections only from that client, starts sessions only for the helper beside it, and runs only the payloads it pinned. The client accepts only a daemon running as root in the system domain. Neither checks a team or a bundle identifier, so the daemon works under any app's identity, as long as nobody re-signs the client, the server or the supervisor. `omarchy-network-daemon check`, run without privileges, checks the runtime beside it and prints the service name, or says what differs and exits 1.

When a start asks for bridged networking, the kit's run mode asks the daemon, through the client, whether it serves this copy of the kit. The answer comes at once when the daemon is not registered, not approved or serves another copy. Then:

- a stored bridged choice starts with shared networking: the run mode writes a `notice` with the code `bridged-network-unavailable` before any progress, and the client's answer to standard error;
- a configuration that asks for bridged networking fails with `bridged-network-unavailable`.

In the settings window, the network section shows what the start found, without Set Up or Remove, because the embedding app owns the registration. The full app, and the run mode started from the full app, register and repair their own daemon as before.

### What the embedding app does

1. It copies the kit's job to its own `Contents/Library/LaunchDaemons/dev.tryomarchy.kit.network.plist`, named after the job's `Label`, and sets `BundleProgram` to the daemon's path inside its bundle, such as `Contents/Helpers/TryOmarchyKit.bundle/Contents/MacOS/omarchy-network-daemon`.
2. It signs the daemon as itself, with the hardened runtime, and leaves `socket_vmnet`, `omarchy-network-supervisor` and `omarchy-network-client` as the kit signed them. Its assembly test runs `omarchy-network-daemon check` in the signed app and expects `dev.tryomarchy.kit.network`.
3. On the `bridged-network-unavailable` notice, it offers to set up bridged networking. From its own process, with `SMAppService.daemon(plistName: "dev.tryomarchy.kit.network.plist")`, it calls `register()` when the daemon is not registered, and `SMAppService.openSystemSettingsLoginItems()` while it needs approval. The next start uses it.
4. To repair, it unregisters and registers again; to remove, it unregisters. Either interrupts a bridged session, so it shuts Omarchy down first.

A fetched kit lives outside the embedding app's bundle, and the registered daemon serves only the kit beside it. So a fetched kit starts a stored bridged choice with shared networking and the notice. Bridged networking from a fetched kit needs the daemon to trust signatures it can check on a kit outside the bundle, instead of pinned bytes.

## Sharing a VM

The full app and an embedding app open the same VM in the default folder ([finding the VM](#finding-the-vm)), never at once: the VM folder's lock refuses the second. The run mode reports `vm-already-open`, and the full app says that Omarchy is open in another app, such as Omarchy Installer. Either can boot a VM the other made. The `try-omarchy` package only upgrades, so an older kit never downgrades the guest. A launcher refuses a VM whose `vm.json` names a storage layout it does not know (`storage-layout-unknown`).
