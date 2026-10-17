# Factory image

This directory builds the factory disk the app ships, as described in
[the architecture](../../docs/architecture.md#the-factory-disk) and
[the shell plan](../../docs/shell-plan.md).

The image is a stock generic-`aarch64` Omarchy install, built from Omarchy's
own package repositories with upstream's own install steps. Try Omarchy adds
exactly one package to it, [`try-omarchy`](../package/README.md).

```sh
make guest
```

This runs `guest/build.sh`, which builds the `try-omarchy` package and then the
image in a privileged ARM64 container. The output goes to `dist/guest/`:

| File | Contents |
| --- | --- |
| `omarchy-aarch64-edge.img.zst` | The disk image (20 GiB virtual, sparse) |
| `factory.json` | Identity, versions, the image's digests, the boot method, and the digest of each repository database it was built from |
| `packages.txt` | Every installed package and version |
| `unavailable.txt` | Default-set names the aarch64 repositories do not carry |
| `packages/try-omarchy-*.pkg.tar.zst` | The integration package installed in the image |

The build cache skips the build while the inputs under `guest/` are
unchanged. `make guest FORCE=1` rebuilds against the repositories' current
state. Package downloads are cached in a Docker volume labeled
`dev.tryomarchy.role=upstream-work`. `make clean` removes it.

Lower-level commands:

```sh
guest/factory/build-container.sh --output dist/guest --package dist/guest/packages/try-omarchy-<version>-aarch64.pkg.tar.zst
guest/factory/build-container.sh --size-gib 24   # a larger virtual disk
```

## What the build does

`build-image.sh` follows the omarchy-iso orchestrator's full-disk install:

1. A GPT disk with a 2 GiB vfat ESP mounted at `/boot` and a btrfs root with
   the `@`, `@home`, `@log` and `@pkg` subvolumes (`compress=zstd`). The root
   partition uses the ARM64 root type GUID.
2. `pacstrap` of `base`, `linux-omarchy` and its headers. Then the early
   packages, the runtime, and the aarch64 default set from
   `omarchy-pkg-defaults aarch64`. The default set includes the
   Limine/Snapper stack that UEFI aarch64 machines need.
3. Limine on the ESP, at both `EFI/limine` and the removable fallback path
   `EFI/BOOT/BOOTAA64.EFI`. A new VM's variable store holds no boot entry, so
   the firmware uses the fallback path.
4. The image-target manifest (`format=1`, `platform=aarch64`), then
   `omarchy-apply-system --defer-provisioning --first-install`. Hardware
   setup and the pacman master key are deferred to the VM's first boot.
5. Owner provisioning armed as the ISO arms it, with the Node.js tarball
   stashed for offline user finalization.
6. One UKI build with `limine-update`, and upstream's aarch64 `edge` pacman
   template and mirror list.
7. A full btrfs balance, then `fstrim` of both filesystems, so the free
   space is long zero runs.
8. Sealing: an empty machine ID, no random seed, no SSH host keys, no pacman
   keyring, an empty package cache, and a read-only `@factory` snapshot for
   Omarchy's own factory reset.

On aarch64 the `edge` channel installs `omarchy-dev` and
`omarchy-settings-dev`, as `omarchy-channel-set edge` does. Those packages are
built from Omarchy's `quattro` branch, where the aarch64 platform support
lives. The `omarchy` release package on the same repository predates that
support. It has no `omarchy-pkg-defaults`, platform detector or image-target
support.

## Reproducibility

The repositories are live. `factory.json` records the `[omarchy]` database
digest the build resolved against, and `packages.txt` records every version.
Two builds from the same database digest install the same `[omarchy]`
packages. Arch Linux ARM has no frozen snapshot, so its packages can still
differ.

On first use the app decompresses the image once per factory into
`<VM storage>/shell-factory/`. It then returns the zero blocks to APFS
(`omarchy-vm-helper --sparsify`; about 9 GB stays allocated) and clones that
file for each new VM.
