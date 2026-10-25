# Native install export

Status: built end to end. The installer stages the chosen export onto the native disk, and the native system claims it at first boot and offers to import it ([native import](https://github.com/omacom/omarchy-mac-installer/blob/main/docs/native-import.md)).

Someone who runs Omarchy in the VM from the Omarchy installer can move their home folder to Omarchy installed on the Mac itself. Try Omarchy on its own doesn't offer it, since only the installer takes exports. The guest produces an encrypted export, the launcher moves it into a folder the Omarchy installer reads, and the installer brings it to the native install. The exporter, the bundle format and the receipt belong to `omarchy-migration`, in the [installer's repository](https://github.com/omacom/omarchy-mac-installer). This page describes the parts inside Try and the contract between them and the installer.

## The flow

1. In Omarchy, the user chooses **Setup → Move to Native Install** in the Omarchy menu. The row shows only while the app offers the outbox share. It opens a floating terminal, like **Import Previous VM**.
2. `try-omarchy-export-home` says what is exported and what stays behind, and asks for a transfer passphrase of at least 12 characters, twice. The passphrase stays in the guest.
3. Through `sudo` with no password, a root helper takes a read-only btrfs snapshot of `/home` and bind-mounts it read-only, so the running desktop can't change files during the export.
4. The helper runs `omarchy-migration export` as the owner, with the snapshot as a read-only source, scratch in `/tmp` and the passphrase on a descriptor.
5. Only `bundle.age` and `receipt.json` reach the Mac, through the outbox share. The helper removes the snapshot and tells the user to shut down Omarchy.
6. When the VM stops, and again when it next starts, the launcher publishes the outbox into Exports.
7. In the Omarchy installer, **Migrate to Native** finds the export, checks it against its receipt, and carries it into the install.

The installer starts the VM through the kit's run mode. Its configuration asks for the outbox with `nativeExports`, and only an installer that can stage the export onto the native disk asks. The run mode then asks the launch script for the outbox. Try Omarchy starts the VM through the same script without asking, so its VMs get no outbox and no menu row. So does a newer kit under an older installer.

## In the guest

- `/usr/bin/try-omarchy-export-home` is the menu row's command. It asks for the passphrase and runs the helper.
- `/usr/lib/try-omarchy/export-home` is the root half. It takes no arguments and reads the passphrase as one line on standard input. `/etc/sudoers.d/try-omarchy-export` lets members of `wheel` run it, without arguments, without a password.
- The exporter and `age` 1.3.2 ship in the `try-omarchy` package under `/usr/lib/try-omarchy/migration/`, so an export works offline on every VM. The `PKGBUILD` pins `age` by its release checksum and the binary's digest, and the exporter by its commit and archive checksum. The helper checks the `age` digest before each export.
- The exporter's policy, one per Try build, decides what stays behind: Try's menu rows, the VM's Hyprland and display settings, the idle overrides, the Fcitx config, SSH and GPG keys, browser data and saved credentials. A change to a file the policy cites needs a new policy revision in the exporter. `make test-guest-install`, and CI's guest package job, run `guest/tests/migration-policy.sh`, which fails when the built package's policy no longer matches the tree.

VMs from before the shell, a bare ext4 root in `disks/`, are not exported. Import them first with **Import Previous VM**.

## The outbox share

With `OMARCHY_QEMU_GPU_NATIVE_EXPORTS=1`, which only the run mode sets when its configuration asks, the launcher creates `native-exports` beside `shell` in the VM storage folder, private to the user, and attaches it as a writable virtio-9p share with mount tag `tryomarchy-native-exports`. Try Omarchy strips the setting from its own launches. The guest sees the Mac user as the Omarchy owner account, as on the Mac shared folder. A disposable VM gets no outbox even when asked: it holds no lock on the storage folder, so another VM may be exporting into it, and its home is thrown away.

The host settings line, published in the guest at `/run/try-omarchy/cmdline`, carries `tryomarchy.native_exports=1` whenever the share is attached. The menu row shows on that token. The helper mounts the tag itself, under `/run/try-omarchy/export.*/`, and unmounts it when done.

One folder per export, named by the receipt's `export_id`, a canonical lowercase UUID, holds exactly two files:

```text
native-exports/
└── <export id>/
    ├── bundle.age
    └── receipt.json
```

The guest assembles an export in a hidden folder and renames it to `<export id>/` once both files are complete, so the Mac never takes a half-written export. Nothing else belongs in the outbox. The guest keeps no copy.

## Publishing

Exports live in `~/Library/Application Support/Try Omarchy/Exports/<export id>/`, the folder the Omarchy installer reads, whichever folder holds the VM. The launcher runs the publish script, which lives in `macos/` and ships in the app's `Resources/scripts`:

```text
publish-migration-exports.sh --outbox <outbox> --destination <exports>
```

When it attaches the outbox, the launcher calls it twice per launch: right after the storage folder is open, before QEMU starts, and in its cleanup, after QEMU has exited. The app and the run mode forward a quit to the launcher script as a signal, so the cleanup call runs for a guest shutdown and for an app quit alike. A missing script is skipped. A failing one is logged. Neither stops a launch or a shutdown. Tests redirect Exports with `OMARCHY_QEMU_GPU_EXPORTS_ROOT`.

The script treats the outbox as untrusted. For each `<export id>/` it checks the exact layout, that the folder name equals the receipt's `export_id`, that the receipt is an `omarchy-migration/receipt/1` document for an `age-v1-scrypt` bundle, and that `bundle.age` has the receipt's byte count, an age header and the receipt's SHA-256. A valid export is cloned, or copied across volumes, into a hidden folder in Exports and renamed to `<export id>/`, never replacing an export that exists. The published files are private to the user. Everything in the outbox is then removed, including hidden folders, invalid exports and exports already published. An empty outbox leaves Exports as it is. The script exits 0 whether or not there was anything to publish. A non-zero exit means it could not do its job at all.

## In the Omarchy installer

Once a VM exists, **Install on this Mac** reads **Migrate to Native** ([install from Try](one-app.md#install-from-try)). It opens a sheet that depends on what it finds:

- **An export in Exports:** it names the newest export and checks it against its receipt, without the passphrase. **Install with These Files** shuts Omarchy down if it runs and continues into the plan with that export chosen.
- **A finished export still in the outbox:** Omarchy is running, so the export isn't published yet. **Shut Down Omarchy** shuts it down. The launcher publishes the export, and the sheet then offers it as above.
- **No export:** the sheet says how to make one with **Setup → Move to Native Install** in Omarchy.

Each case keeps **Install Without Migrating** and **Cancel**. The installer only reads the outbox to tell the second case from the third; it takes exports from Exports alone.

The installer accepts only age's default passphrase format: exactly one scrypt recipient at work factor 18, which is what the pinned `age` writes. Changing either side's `age` means checking that the other still agrees.

## Why it is encrypted

The bundle stays encrypted from the guest until the person types the transfer passphrase on the native system. During a native install it waits on a drive that is not yet encrypted at the disk level, and before the person's account exists, so the Exports folder's permissions alone would not protect it. `age` also detects any change to it. The installer never handles it in plaintext.

## Not built yet

- Removing an export once the native install has imported it. Exports stay in Exports and the VM stays in place.
