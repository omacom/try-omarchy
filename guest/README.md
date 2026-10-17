# Guest

The guest is a stock generic-`aarch64` Omarchy install plus one package. This
directory builds both:

| Path | Contents |
| --- | --- |
| [`package/`](package/README.md) | The `try-omarchy` pacman package: every Mac integration in the guest |
| [`factory/`](factory/README.md) | The factory disk the app ships, built with Omarchy's own install steps |
| `build.sh` | Builds the package, then the factory with the package installed |
| `keys/` | Omarchy's reviewed repository keys for the builder |
| `vendor/omarchy-pkgs/pacstrap-docker` | A mount-free `pacstrap` for bootstrapping the builder |

From the repository root:

```sh
make guest           # dist/guest: the factory disk, its manifest, and packages/
make guest-package   # only dist/guest/packages/try-omarchy-<version>-aarch64.pkg.tar.zst
make test-guest      # the package's contract tests
```

Both builds run in a privileged ARM64 Docker container (the builder image is
`guest/factory/Containerfile`). The build cache skips `make guest` while the
inputs under `guest/` are unchanged; `make guest FORCE=1` rebuilds the factory
against Omarchy's current `edge` repositories. `make guest-package` does not
invalidate the factory: the next `make app` bundles the new package, and the
app offers it to existing VMs at their next boot.

## Repository keys

The builder imports Omarchy's keyring from `keys/omarchy.gpg`,
`keys/omarchy-trusted` and `keys/omarchy-revoked` without a keyserver lookup.
They were copied from `pkgbuilds/omarchy-keyring/` at `omacom-io/omarchy-pkgs`
commit `7e448b90313fea4fb78da9a78607287691d3b241`. The signing fingerprint is
`40DFB630FF42BCFFB047046CF0134EE680CAC571`. Their SHA-256 digests are:

```text
15d6aac44df688165b2ea35fe0b23af239bbc66a6909c10a5c219e8d94b707de  omarchy.gpg
ab0b688815444cffd48d15ca3597c77dbb364d59763c5784fca36691520f00fd  omarchy-trusted
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  omarchy-revoked
```

The Arch Linux ARM keyring is downloaded from a pinned
`archlinuxarm/PKGBUILDs` commit and checked against fixed digests in the
Containerfile. Package signatures remain required throughout. The factory keeps
no keyring: every VM creates its own on first boot, as Omarchy's image-target
manifest requests.

## Supported guest

The app ships one factory and launches one VM per storage folder. VMs created
by earlier direct-boot versions of the app (the pinned, patched image this
directory used to build) are not launched; their disks are left untouched and
attached read-only for `try-omarchy-import-previous`.
