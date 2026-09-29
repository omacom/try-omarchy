# Reviewed ABI package pins

Recipes here are factory-build inputs for the compatible Hyprland dependency
set that Arch Linux ARM's rolling repositories no longer provide together.

The factory's ARM repositories use the official HTTPS mirrors selected by
`inputs.packageRepositoryMirrors` in `guest/spec.json`. The previous community
snapshot host stopped resolving in September 2026. Package signatures remain
required, and the complete resolved transaction must match
`guest/packages.lock.json`; a rolling mirror change fails until the lock is
intentionally refreshed and reviewed. The installed guest retains its normal
mirror configuration. The builder tries the second mirror if a package
download fails on the first.

Hyprland 0.56.2 and aquamarine 0.15.1 use `libaquamarine.so=14` together.
The rounded-border backport still applies unchanged to the newer Hyprland.

- `aquamarine/PKGBUILD` adapts the reviewed Arch `0.14.0-2` recipe for
  aquamarine `0.15.1-1` on aarch64, with the new upstream archive checksum.
- `hyprtoolkit/PKGBUILD` adapts Arch `0.5.4-6` packaging for aarch64 and uses
  package release `6.2` to distinguish the local rebuild.
- `hyprland-guiutils/PKGBUILD` adapts Arch `0.2.2-3` packaging and uses
  package release `3.1` to rebuild against Hyprtoolkit ABI 5. The rolling ARM
  binary of `0.2.2-3` instead requires ABI 6.

Packaging commits, recipe digests, upstream tarball digests, and reproduced
library digests are pinned in `guest/spec.json`. The factory builds aquamarine
first, installs that verified result in the disposable builder, then builds
Hyprtoolkit against `libaquamarine.so=14`, then GUI utilities against that
Hyprtoolkit. Random build paths are remapped out of compiler output. Package
metadata, library digests, and the GUI utilities executable digest are checked
before publishing the temporary `[try-omarchy-abi-pins]` repository.

The finished guest never receives that builder repository. It holds aquamarine
and Hyprtoolkit alongside the patched Hyprland on `IgnorePkg`. It also holds
`hyprland-guiutils`, whose newer builds can require a `libhyprtoolkit.so` ABI
that the held Hyprtoolkit does not provide. Remove these holds together only
when the patched compositor, libraries, and GUI utilities have been validated
against a newer ABI.

The builder seeds Omarchy's keyring from the unmodified files in
`guest/keys/omarchy*`, taken from `pkgbuilds/omarchy-keyring/` at the already
pinned `omacom-io/omarchy-pkgs` commit
`7e448b90313fea4fb78da9a78607287691d3b241`. Their SHA-256 digests are checked
before import. The signing fingerprint is
`40DFB630FF42BCFFB047046CF0134EE680CAC571`. The fresh guest receives its own
local keypair and the reviewed ARM and Omarchy repository keys before package
installation, avoiding any keyserver lookup to bootstrap `omarchy-keyring`.
