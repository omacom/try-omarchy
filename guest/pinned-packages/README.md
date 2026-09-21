# Reviewed ABI package pins

Recipes here are factory-build inputs for the compatible Hyprland dependency
set that Arch Linux ARM's rolling repositories no longer provide together.

The factory's ARM repositories use the dated archive in
`inputs.packageRepositorySnapshot` in `guest/spec.json`. This keeps the
upstream Hyprland package on the ABI expected by these rebuilds. Package
signatures remain required, and the complete resolved transaction must match
`guest/packages.lock.json`. The archive is only used by the factory builder;
the installed guest retains its normal mirror configuration. When updating
the snapshot, refresh and review the lockfile together with it.

- `aquamarine/PKGBUILD` adapts Arch `0.14.0-2` packaging for aarch64.
- `hyprtoolkit/PKGBUILD` adapts Arch `0.5.4-6` packaging for aarch64 and uses
  package release `6.1` to distinguish the rebuild against aquamarine 0.14.

Packaging commits, recipe digests, upstream tarball digests, and reproduced
library digests are pinned in `guest/spec.json`. The factory builds aquamarine
first, installs that verified result in the disposable builder, then builds
Hyprtoolkit against `libaquamarine.so=13`. Random build paths are remapped out
of compiler output. Both package metadata and library digests are checked
before publishing the temporary `[try-omarchy-abi-pins]` repository.

The finished guest never receives that builder repository. It holds aquamarine
and Hyprtoolkit alongside the patched Hyprland on `IgnorePkg`. Remove these
holds together only when the patched compositor and its dependency set have
been validated against a newer ABI.
