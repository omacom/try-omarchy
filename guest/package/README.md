# try-omarchy guest package

`try-omarchy` holds everything Try Omarchy adds to a stock aarch64 Omarchy
install running in the Mac app (see [the shell plan](../../docs/shell-plan.md)):

- the host bridges: clipboard, audio, camera, battery (including the DKMS
  `try-omarchy-battery` module), time zone, Touch ID for sudo, and the
  settings port;
- the Mac shared folder mount and the home-folder link;
- the launcher's per-boot settings;
- first-boot language seeding;
- SSH on demand;
- root filesystem growth;
- the Hyprland display and input profile for the VM;
- the guest status reporter and the **Update integrations** installer.

```sh
make upstream-package   # dist/upstream-guest/packages/try-omarchy-<version>-aarch64.pkg.tar.zst
make test-upstream      # contract tests for the package's scripts and layout
```

## Rules

- **No file another package owns is edited.** The package installs under
  `/usr`, plus `/etc/UPower/UPower.conf.d` and a fontconfig link. Nothing
  goes under `/usr/local`, `/usr/share/omarchy` or `/etc/skel`.
  Customisation uses systemd drop-ins, presets and udev rules, plus one
  loader in the user's Omarchy toggles directory.
- **No kernel command line.** The guest owns its boot. The app passes its
  settings as the systemd credential `tryomarchy.host` (SMBIOS type 11), one
  line of the same tokens the direct-boot launcher put on the kernel command
  line. `try-omarchy-host-config.service` publishes them at
  `/run/try-omarchy/cmdline` for the other units and scripts to read.
- **Units are enabled by preset.** They are enabled on first install. A unit
  added in a later release is enabled by name in `post_upgrade`.

## Host interfaces

| Port or share | Direction | Use |
| --- | --- | --- |
| credential `tryomarchy.host` | host → guest | Keyboard geometry, locale, time zone, shared folder name, SSH, VirGL flags |
| credential `tryomarchy.package` + 9p `tryomarchy-packages` | host → guest | One package for **Update integrations**, installed before login |
| `dev.tryomarchy.guest` | guest → host | Status reports (protocol 1, JSON lines every 10 s) |
| `dev.tryomarchy.{audio,clipboard,camera,battery,timezone,authentication,settings}` | both | The same bridges and protocols as the direct-boot guest |

A status report looks like this:

```json
{"channel":"edge","kernel":{"installed":"7.2.8-11","running":"7.2.8-11-omarchy"},
 "omarchy":"4.0.0.r7024.g246f33a-1","package":"0.1.0-1","protocol":1}
```

The app reads only the fields it knows. A guest ignores any port it does not
know about. Either side can therefore be updated first.

## Hyprland

Omarchy has no system-wide Hyprland drop-in directory. At the owner's first
provisioning and at every graphical login, `user-setup` places one loader at
`~/.local/state/omarchy/toggles/hypr/zz-try-omarchy.lua`. Omarchy loads that
directory after the user's own configuration on every reload. The loader runs
`/usr/share/try-omarchy/hyprland.lua`, which the package owns. That file
hides the guest cursor (Cocoa draws the Mac's), keeps the mode in sync with
the window through EDID, and applies the pinch and Apple keyboard input
rules.
