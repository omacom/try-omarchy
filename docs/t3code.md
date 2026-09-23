# T3 Code desktop on ARM64

Choose **Install → AI → T3 Code** in the Omarchy menu. The installer downloads
the latest stable official Linux ARM64 Electron release, packages it as
`t3code-bin`, applies the current Omarchy palette, and opens the desktop app.
The factory contains only the installer; T3 Code is downloaded on demand.

**Update → Omarchy** (or `omarchy update`) checks the same release feed after
system packages update. It upgrades T3 Code only if it is installed, skips
versions that are already current, refuses downgrades, and respects Pacman's
`IgnorePkg` patterns. Removing the app through **Remove → AI → T3 Code** stops
future updates; Omarchy's removal command also deletes its configuration and
workspaces. Close the app before updating and reopen it afterwards to use the
new version.

The package is registered in the local Try Omarchy Pacman repository so AUR
updates cannot replace it with an x86-only package. Run `pacman -Q t3code-bin`
to see the installed version. `~/.config/t3code-flags.conf` accepts one Electron
argument per line; comments and blank lines are ignored.

## Existing VMs

Replacing the Mac app does not migrate this integration onto an existing disk.
From an updated Try Omarchy checkout inside the guest, run:

```sh
sudo python3 guest/scripts/install-t3code-integration.py
```

Then use **Install → AI → T3 Code**. This migration verifies the existing
installer/updater commands against their reviewed preimages, keeps backups in
`/var/lib/try-omarchy/t3code-integration-backup.*`, and preserves unrelated build
metadata and app state. It refuses commands with unrecognized local edits.
It modifies two installed runtime commands; a reinstall of the old runtime
package can overwrite them, so rerun the migration afterwards. New factory
builds own these changes and the installer assets in `try-omarchy-runtime`.

## Release verification and failure behavior

The installer code and packaging template are reviewed, checksum-pinned factory
inputs. The application is deliberately a mutable post-build dependency: the
installer queries `pingdotgg/t3code`'s GitHub latest-release API, requires a
stable version and the exact ARM64 asset URL, and verifies the download against
the SHA-256 digest supplied by GitHub. This trusts the upstream GitHub release
account and HTTPS; it is not an independently signed or factory-pinned app.
No downloaded shell script or packaging recipe is executed.

Network, rate-limit, missing-asset, checksum, or packaging errors stop before
replacing the installed app and are reported by the update command. There is no
fallback to an old bundled version. Retry the normal update once the problem
is resolved. New upstream layouts that break packaging require an installer
update rather than bypassing verification. Plain `pacman -Syu` does not refresh
the T3 Code release feed; use Omarchy's updater.

For an unprivileged package build using the checkout's installer inputs:

```sh
guest/native-overlay/usr/local/lib/try-omarchy/install-t3code-arm64 \
  --from-checkout "$PWD" --build-only /tmp/t3code-package
```

Missing package dependencies still use Omarchy's usual privileged package
installer. Downloading, extracting, and packaging run as the normal user.
