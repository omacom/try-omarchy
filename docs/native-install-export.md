# Native install export

Status: contract agreed on 2026-10-23. The app side is built; the guest command and the publish script are built against this document.

Someone who has used Omarchy in the VM can move their home folder to Omarchy installed on the Mac itself. The guest produces an encrypted export, the app moves it into a folder the Omarchy installer watches, and the installer restores it on the native install. The exporter, the bundle format and the receipt belong to `omarchy-migration`, in the [installer's repository](https://github.com/omacom/omarchy-mac-installer). This page describes only the two halves inside Try Omarchy and the contract between them.

## The flow

1. In Omarchy, the user chooses **Setup → Move to Native Install** in the Omarchy menu. The row shows only while the app offers the outbox share. It opens a floating terminal, like **Import Previous VM**.
2. The command `try-omarchy-export-home` explains what is exported and asks for a transfer passphrase twice. The passphrase stays in the guest.
3. With a narrow `sudoers.d` rule, like the time zone one, a root helper takes a read-only btrfs snapshot of `/home` and mounts it read-only. The exporter requires a home on a read-only mount.
4. The command runs `omarchy-migration export` as the owner, with the snapshot as a read-only source and the passphrase on a descriptor. The exporter and a pinned `age` come with the `try-omarchy` package.
5. Only `bundle.age` and `receipt.json` reach the Mac, through the outbox share. The command removes the snapshot and tells the user to shut down Omarchy.
6. When the VM starts and when it stops, the launcher publishes the outbox into Exports. The installer finds the export there and verifies it against its receipt.

## The outbox share

The launcher creates `native-exports` beside `shell` in the VM storage folder, private to the user, and attaches it to every VM as a writable virtio-9p share with mount tag `tryomarchy-native-exports`. The guest sees the Mac user as the Omarchy owner account, as on the Mac shared folder. The share is offered to disposable VMs too, so the end-to-end run can exercise it.

The host settings line (the `tryomarchy.host` credential, published in the guest at `/run/try-omarchy/cmdline`) carries `tryomarchy.native_exports=1` whenever the share is attached. The guest's menu row shows on that token:

```text
grep -qw tryomarchy.native_exports=1 /run/try-omarchy/cmdline
```

The guest command mounts the tag itself, at `/run/try-omarchy/native-exports`, the way `package-install` mounts the package share, and unmounts it when done.

### What the guest writes

One folder per export, named by the receipt's `export_id` (a canonical lowercase UUID), holding exactly two files:

```text
native-exports/
└── <export id>/
    ├── bundle.age
    └── receipt.json
```

The guest assembles the folder as `.<export id>.partial/` and renames it to `<export id>/` once both files are complete, so the Mac never sees a half-written export. Nothing else belongs in the outbox. The guest keeps no copy: a published export lives only in Exports.

## Publishing

Exports live in `~/Library/Application Support/Try Omarchy/Exports/<export id>/`, the folder the Omarchy installer reads. The launcher never writes there itself. The launcher window's **Virtual Machine → Native Install → Show Exports** opens the folder, and creates it private to the user if it is missing. It runs the publish script with the outbox and the Exports folder as its two arguments:

```text
publish-migration-exports.sh <outbox> <exports>
```

The launcher calls it twice per launch: right after the storage folder is open, before QEMU starts, and in its cleanup, after QEMU has exited. The app forwards its quit to the launcher script as a signal, so the cleanup call runs for a guest shutdown and for an app quit alike. A missing script is skipped. A failing one is logged. Neither stops a launch or a shutdown. The script lives in `macos/` and `build-app.sh` must copy it into the app's `Resources/scripts` by name, as it does the other launcher scripts. Tests redirect Exports with `OMARCHY_QEMU_GPU_EXPORTS_ROOT`.

The script treats the outbox as untrusted. For each `<export id>/` it checks the exact layout, that the folder name equals the receipt's `export_id`, that the receipt is a valid `omarchy-migration/receipt/1` document, and that `bundle.age` has the receipt's byte count and SHA-256. A valid export is published atomically: copied into `Exports/.<export id>.partial/`, then renamed to `Exports/<export id>/`, never replacing an export that exists, with the published files readable by the user. The outbox copy is removed after the publish. Anything else in the outbox, including a partial folder, an invalid export or an export whose id is already published, is removed. The script prints what it did to stderr and exits 0 whether or not there was anything to publish. A non-zero exit means it could not do its job at all.

## What the installer needs

Only Exports: `bundle.age` and `receipt.json` under `<export id>/`. How Try produced them is invisible to it. The receipt carries no file names or private paths; the installer verifies the bundle against the receipt's digest, and the importer authenticates the contents with the transfer passphrase.

## Boundaries

- VMs from before the shell (a bare ext4 root in `disks/`) are not exported. Import them first with **Import Previous VM**.
- The app publishes at start and stop only. There is no guest hint while the VM runs.
- The bundle is encrypted with `age`, as the exporter's `age-v1-scrypt` format requires. The export outlives the VM: the installer stages it on the native disk before the user's account exists, so the Exports folder's permissions alone would not protect it.
