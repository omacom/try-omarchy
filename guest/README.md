# ARM64 guest image

This directory builds the single guest supported by Try Omarchy: our own
unprovisioned ARM64 Arch Linux factory image containing pinned upstream Omarchy
source. It is not a prebuilt image published by Basecamp.

From the repository root:

```sh
make guest
```

The privileged ARM64 Docker build writes verified artifacts to `dist/guest/`.
Its persistent package/source cache lives in a project-scoped Docker volume, so
repeat builds do not start from zero.

Useful lower-level commands:

```sh
guest/build-container.sh --dry-run
guest/build-container.sh --output dist/guest
guest/build-container.sh --refresh-package-lock /tmp/packages.lock.json
guest/test
```

`spec.json` is the authoritative image and runtime contract. `packages.txt` is
the requested transaction and `packages.lock.json` pins the full resolved ARM64
package set. Source repositories, commits, downloads, versions, and hashes are
reviewed inputs rather than floating build dependencies.

Hyprland is the one source-patched guest package. It is rebuilt from verified
upstream source with the rounded-border VM-graphics compatibility patch declared
under `supplyChain.hyprland` in `spec.json`, then held in the image's local
repository. `scripts/register-patched-hyprland.sh` owns the reproducible package
build, and `tests/test_rounded_border_coverage.py` owns its focused regression
model.

When updating Hyprland, first test the unpatched package through the same
Virtio/VirGL guest path. Remove the local patch and package hold if upstream is
clean; otherwise rebase the patch and update every source, patch, toolchain,
binary, package, and launcher identity together. In either case, run the full
tests and verify the newly built factory artifact. Installing a new app does
not rewrite existing persistent VMs, so they are not evidence that the new
factory contents are correct.

The output includes the kernel, initramfs, raw and compressed ext4 image,
provenance, package inventory, licenses, manifest, and SHA-256 sums. Generated
output belongs under the repository's ignored `dist/` directory and must not be
committed.

The factory is a seed, not an update payload. A new or reset persistent VM and
every ephemeral VM use the current output. An existing persistent VM keeps its
writable disk and a validated copy of the kernel and initramfs originally paired
with that disk, so a later app release does not replace its guest files. VMs
from before paired boot kits are migrated once by a recovery initramfs that
reads their `/boot` directory with the root disk mounted read-only.

Omarchy's built-in updater remains available for updates supported by this ARM
guest, but it is not equivalent to installing a new Try Omarchy factory. The
direct-boot kernel and matching headers are held, while the packaged
`try-omarchy-runtime` and reviewed backports resolve from the immutable local
repository. A separate migration channel is required before those
Try-Omarchy-specific revisions can advance on an existing disk without reset.

The kernel reboot check recognizes package-owned `modules.builtin` metadata as
well as `vmlinuz` under `/usr/lib/modules/<release>/`. Arch Linux ARM does not
place `vmlinuz` there, so requiring that file alone produces a false kernel-update
prompt after every no-op update. A matching release suppresses that prompt;
unrecognized layouts report that kernel reboot status could not be determined
instead of claiming either a match or an update. Other reboot and service-restart
reasons still apply. This check ships as the `update-restart-arm-kernel` reviewed
backport, with a fixture from the pinned upstream command for regression tests.

The factory includes the pinned upstream `omarchy-dns` and
`omarchy-theme-browser` sudoers drop-ins, owned by `try-omarchy-runtime` with
root ownership and mode `0440`. These grant wheel users passwordless access
only to the upstream DNS presets and browser theme-color helper, so those menu
actions do not fall back to a polkit password prompt. Other sudo operations
retain their existing password or opt-in Touch ID authentication. As with other
factory changes, replacing the Mac app does not add these files to an existing VM.

The default Tokyo Night wallpaper is seeded as a per-user background at
`native-overlay/etc/skel/.config/omarchy/backgrounds/tokyo-night/try-omarchy-wallpaper.jpg`.
Omarchy checks that directory before the packaged theme backgrounds during
first-time owner provisioning, so the project image becomes the default without
changing the pinned upstream theme tree. The narrowly audited
`omarchy-theme-bg-switcher` override passes the same directory to the picker
first, making the project wallpaper its first option as well.

OpenSSH is an explicit factory package. A systemd generator requests the vendor
`sshd.service` only for a boot carrying the exact
`tryomarchy.ssh_access=1` kernel token, which the Mac launcher derives from a
validated generic TCP mapping to guest port 22. The generator writes only to
systemd's runtime generator directory; it does not enable sshd persistently or
change authentication policy under `/etc`.

The vendor service generates missing host keys on the writable guest disk. A
persistent VM therefore keeps its identity across restarts and app updates,
while a Factory Reset or a fresh ephemeral VM gets a new identity. The factory
image must never contain shared SSH host private keys.

## Night light

**Super + Ctrl + N** and the night-light indicator use the same manual toggle
in the VM. Virtio GPU does not expose the DRM colour-transform property used
by `hyprsunset`, so the native guest applies the 4000 K tint with a final screen
shader instead. Turning it off removes that shader. A user's existing screen
shader is never overwritten: enabling night light reports a conflict, and
disabling it leaves any subsequently selected custom shader alone.

The setting lasts until a Hyprland configuration reload or logout; its status
is read from the compositor, and the indicator refreshes after a reload. This
fallback does not implement `hyprsunset.conf` schedules, arbitrary temperatures,
or gamma adjustment. Non-VM sessions retain the upstream `hyprsunset` backend.
Hyprland's guest screenshot path omits the final tint on the pinned compositor;
capture the Mac window to show what is displayed.

Updating the Mac app does not modify an existing guest. From this checkout
**inside Omarchy**, preview and install the fix with:

```sh
python3 guest/scripts/install-nightlight.py
sudo python3 guest/scripts/install-nightlight.py --apply
omarchy restart shell
```

The installer only accepts the pinned original files or an already installed
copy of this backport. It refuses local changes, installs the command, service,
helper and shader, and prints a backup under
`/var/lib/try-omarchy/nightlight-backup.*`. Repeating it is a no-op. This is a
local backport to package-owned files on existing guests; reinstalling their
older runtime package can replace it. Fresh images own the fix and both assets
in `try-omarchy-runtime`.

To undo an existing-guest installation, first turn night light off. Using the
printed backup directory, restore its `usr/` contents to `/usr/`, remove only
the newly created paths listed in its `created-files.json`, and run
`omarchy restart shell` again. No user Hyprland configuration is changed.

## Settings access from an existing VM

New factory images include **Setup → Try Omarchy Settings** and a searchable
application entry. Both run `omarchy-native-settings`, which sends
`open-settings\n` through `/dev/virtio-ports/dev.tryomarchy.settings`. The Mac
app replies `opened\n` after presenting its window, or `unavailable\n` if it
cannot present settings. The command times out after three seconds and reports
errors through a desktop notification and stderr. The channel only opens the
settings UI; it does not accept preference values or other host commands.

The updated Mac app installs these entry points on existing disks at boot. A
separate read-only 9p share contains only the bundled settings installer and its
files. A systemd boot credential supplies a temporary service that installs
those files, reloads the udev rule, and unmounts the share. This uses systemd's
extra-unit credentials (available since version 256, included in the supported
factory guest) and leaves the guest's default boot target unchanged. Failure is
logged under `try-omarchy-settings.service` and does not prevent normal boot.
The service has a 20-second timeout and retries on the next launch.

Installation is idempotent. It does not reset the disk, upgrade Linux packages,
or require network access or a user `sudo` command. Existing user menu files
are preserved; those users can search for **Try Omarchy Settings** in the
application launcher. Accounts without a custom extension file also receive
**Setup → Try Omarchy Settings**. Home-directory operations run as that user.

The settings window saves CPU, memory, sharing, port forwarding, and immersive mode for the
next QEMU launch. **Restart Try Omarchy…** requests a clean Linux shutdown and
waits for QEMU to exit before starting a new process with the saved settings.
It never forces a shutdown on a timer. **Shut down to manage…** returns to the
native settings window without automatic startup so location and reset remain
accessible. A normal Linux reboot keeps the current QEMU process and therefore
does not apply these launch settings.
