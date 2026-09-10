# Enable accelerated Alacritty in an existing guest

New factory images use the packaged Alacritty binary directly. An existing VM
may still contain the factory `/usr/local/bin/alacritty` wrapper that forces
software rendering. Updating the Mac app does not replace files in an existing
VM, so retiring that wrapper is a one-time, opt-in step. No factory reset or
package removal is needed.

The migration helper only runs when the current boot advertises
`omarchy.virgl_dual_source=1`, which the launcher supplies with the fixed VirGL
runtime. This marker identifies that specific fix; it is not a claim that every
OpenGL application is compatible. Kitty's separate workaround is unaffected.

## Copy the helper from the installed app

On the Mac, choose the actual location of the updated application, then copy its
bundled helper to a folder you share with the VM. For example, with Downloads
selected as the VM's shared folder:

```sh
APP="/Applications/Try Omarchy.app"
cp -n "$APP/Contents/Resources/scripts/try-omarchy-migrate-alacritty" "$HOME/Downloads/"
```

Restart the VM using the updated app so it receives the runtime marker. Inside
Omarchy, run the copied helper from the shared folder:

```sh
sudo /usr/bin/python3 -I /mnt/mac/try-omarchy-migrate-alacritty
```

Alternatively, copy the same bundled file into the guest using an existing SSH
connection and run it with `sudo /usr/bin/python3 -I /path/to/try-omarchy-migrate-alacritty`.
SSH access and sharing are not enabled automatically by this migration.

## What the helper changes

The helper recognizes the exact factory wrapper by its SHA-256 digest
`9f2da34ccfbbf5402233c1e19ca09197c03c8a7fda3369e4adaaff2d5df7c67e`.
It preserves the original file and its metadata as
`/usr/local/bin/.alacritty.try-omarchy-software-backup`, then removes only the
`/usr/local/bin/alacritty` PATH entry. An existing backup is never overwritten.

Custom contents, symbolic links, hard-linked files, and unprotected files or
directories are left unchanged. A repeated successful run is a no-op. A
“Preserved” result means no wrapper was removed; inspect the reported condition
before making any manual change.

Close and reopen Alacritty afterward. Existing terminal processes keep the
environment they started with. This helper does not change terminal selection,
Alacritty configuration, or the packaged `/usr/bin/alacritty` executable.

The new factory image also includes a marker-gated service that invokes the
helper before the graphical login manager. That service is **not automatically
installed into older guests**; the one-time copied helper is the existing-guest
migration path.

If reverting to an older host runtime, the retained wrapper can be restored
without overwriting a newly created custom wrapper:

```sh
sudo mv -n -- /usr/local/bin/.alacritty.try-omarchy-software-backup /usr/local/bin/alacritty
```

The factory service will retire an exact restored wrapper again on a subsequent
boot with the fixed-runtime marker.
