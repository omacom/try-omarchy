# Integration updates

Three pieces update on their own schedules:

| Piece | Ships through | Who triggers it |
| --- | --- | --- |
| Mac app | DMG ([app updates](app-updates.md)) | The user installs the app |
| `try-omarchy` guest package | Bundled in the app, offered on every boot | Automatic, before login |
| Omarchy, its Hyprland stack and kernel | Omarchy's repositories | `omarchy update` in the guest |

Replacing the app never touches a VM's disk. The guest updates itself.

See [runtime validation](runtime-validation.md) for the tested boot, upgrade,
graphics and host-integration paths, plus the remaining interactive checks.

## The guest package

Every Mac integration in the guest is the `try-omarchy` pacman package
([guest/package](../guest/package/README.md)). The app bundles the package it
was built with, in `Contents/Resources/guest-packages/`.

On every boot the launcher:

1. names that archive in the systemd credential `tryomarchy.package`, and
2. shares it on a read-only virtio-9p share tagged `tryomarchy-packages`.

Before any login, `try-omarchy-package-install.service` compares the offered
version with the installed one (`vercmp`). It installs the archive with
`pacman -U` only when it is newer. A guest that already has the same version,
or a newer one installed in the guest, keeps it. Package
installation uses pacman and the package's own install hooks; there is no
host-side file journal, consent catalog or migration runner.

The result goes to `/var/lib/try-omarchy/package-install.json`
(`installed`, `current` or `failed`, with a message). The status reporter
sends it to the app with the next report.

Developers can turn the offer off with `OMARCHY_SHELL_INSTALL_PACKAGE=` (an
empty value) or name another archive with
`OMARCHY_SHELL_INSTALL_PACKAGE=/path/to/try-omarchy-<version>-aarch64.pkg.tar.zst`.
`make guest-package` rebuilds only the package; the next `make app` bundles
it.

## Status

`try-omarchy-guest-status.service` sends one JSON line every 10 seconds on
`dev.tryomarchy.guest` (protocol 1):

```json
{"channel":"edge","kernel":{"installed":"7.2.8-11","running":"7.2.8-11-omarchy"},
 "omarchy":"4.0.0.r7024.g246f33a-1","package":"0.1.0-1","protocol":1}
```

The app keeps the last report in `<VM storage>/shell/guest-status.json`. The
start menu's **Omarchy** row shows the Omarchy version and channel on one
line and the integration package on the other:

- **Current**: the guest has the bundled package or a newer one.
- **Update pending**: the guest reported an older package. It shows
  `Integrations <installed> → <bundled> next launch`.
- A failed installation shows its message.

Before the first report the row says that versions appear after Omarchy
starts. Reports are advisory: they decide only what the start menu shows.

## Omarchy itself

Omarchy, the kernel and every other package update through `omarchy update`
inside the guest. It takes a Snapper snapshot first; the snapshot appears in
Limine's boot menu for rollback. `omarchy-channel-set` switches channels the
platform has a template for. On ARM, Omarchy publishes only to `edge` for now.

## Compatibility

Every virtio port keeps its protocol. A guest ignores ports it does not know,
and the app reads only the report fields it knows, so either the app or the
guest can be updated first. A guest updated before the app may carry a package
newer than the app's; the app then leaves it alone.

VMs created by earlier direct-boot versions of the app are not launched or
migrated by this version. Their disks stay in the storage folder untouched.
The launcher attaches `disks/current/rootfs.ext4` (or another `disks/*/`
root) to the persistent VM as a read-only virtio disk with serial
`omarchy-previous`, and the package's `try-omarchy-import-previous` copies the
user's files and lists or installs their packages from it. See the
[README](../README.md#existing-vm-data).
