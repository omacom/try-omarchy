# try-omarchy guest package

`try-omarchy` holds everything Try Omarchy adds to a stock aarch64 Omarchy
install running in the Mac app (see [the architecture](../../docs/architecture.md)):

- the host bridges: clipboard, audio, camera, battery (including the DKMS
  `try-omarchy-battery` module, whose source is in `try-omarchy/battery`),
  time zone, Touch ID for sudo and 1Password, and the settings port;
- the Mac shared folder mount and the home-folder link;
- the launcher's per-boot settings;
- first-boot language seeding and the Mac JIS 英数/かな keys;
- SSH on demand;
- `try-omarchy-import-previous`, which copies files and packages from a VM of
  an earlier direct-boot app version that the app attaches read-only;
- root filesystem growth;
- the Hyprland display and input profile for the VM, and the Mac's camera
  notch for Omarchy's bar ([camera notch](../../docs/camera-notch.md));
- the guest status reporter and the integration package installer.

```sh
make guest-package   # dist/guest/packages/try-omarchy-<version>-aarch64.pkg.tar.zst
make test-guest      # contract tests for the package's scripts and layout
```

`build.sh` packs only the files the repository tracks, or new files it does
not ignore, so caches and other local files never reach the package.

## Rules

- **No file another package owns is edited.** The package installs under
  `/usr`, plus `/etc/UPower/UPower.conf.d`, a fontconfig link,
  `/etc/chromium-flags.conf` and
  `/etc/limine-entry-tool.d/50-try-omarchy-console.conf` and
  `50-try-omarchy-cpu.conf` (all pacman `backup` files), Omarchy's sleep switch
  `/etc/systemd/sleep.conf.d/omarchy-sleep-disabled.conf` (a `backup` file;
  the System menu then hides Suspend and Hibernate, which a VM cannot wake
  from), `/etc/sudoers.d/try-omarchy-timezone`,
  `/etc/profile.d/try-omarchy.sh`, the Italian Apple keyboard layout
  `/etc/xkb/symbols/macintosh_vndr/it` (see
  [Mac keyboard geometry](../../docs/mac-keyboard.md)), and one link in
  Omarchy's platform root, `/usr/share/omarchy-platform/display-cutouts.json`,
  to this boot's `/run/try-omarchy/display-cutouts.json` (plain `aarch64` has
  no platform package). Nothing goes under `/usr/local`, `/usr/share/omarchy`
  or `/etc/skel`. Customisation uses
  systemd drop-ins, presets and udev rules, rows in the user's Omarchy menu
  extension, plus one loader in the user's Omarchy toggles directory.
- **No kernel command line from the host.** The guest owns its boot. The app
  passes its settings as the systemd credential `tryomarchy.host` (SMBIOS
  type 11): one line of `key=value` tokens. `try-omarchy-host-config.service` publishes them at
  `/run/try-omarchy/cmdline` for the other units and scripts to read.
- **Upgrades need no downloads.** The app installs this package at a VM's
  boot from its own copy, possibly offline or with a stale package database,
  so every hard dependency is already in the factory image. Anything new the
  guest needs goes to `optdepends`, which the factory build installs from the
  package's metadata.
- **Units are enabled by preset.** They are enabled on first install. A unit
  added in a later release is enabled by name in `post_upgrade`. The install
  also enables `systemd-timesyncd` (once, on upgrades from before `0.1.0-13`),
  which stock Omarchy leaves to the distribution. Removing the package
  disables its own units again.
- **Menu rows go through Omarchy's menu extension.** `menu-entries` adds Try
  Omarchy's rows once each and changes some of Omarchy's: the Timezone row's
  action, and the conditions that show Direct Boot, Firmware, the Wi-Fi and
  Bluetooth restarts, the battery percentage toggle and three game rows.
  Omarchy's merge replaces a row whole, filling every field an extension
  leaves out with a default (its menu documentation says only declared fields
  are replaced), so each changed row carries Omarchy's complete row, read from
  the installed Omarchy at every login, with our change applied. Rows still
  exactly as written follow Omarchy's later changes; rows the user edits or
  removes are left alone.

## Host interfaces

| Port or share | Direction | Use |
| --- | --- | --- |
| credential `tryomarchy.host` | host → guest | Keyboard geometry, locale, time zone, shared folder name, SSH, VirGL flags |
| credential `tryomarchy.package` + 9p `tryomarchy-packages` | host → guest | The app's bundled package, installed before login when newer |
| `dev.tryomarchy.guest` | guest → host | Status reports (protocol 1, JSON lines every 10 s) |
| `dev.tryomarchy.{audio,clipboard,camera,battery,timezone,authentication,settings}` | both | The host bridges, one port per integration |

A status report looks like this:

```json
{"channel":"edge","kernel":{"installed":"7.2.8-11","running":"7.2.8-11-omarchy"},
 "omarchy":"4.0.0.r7024.g246f33a-1","package":"0.1.0-1","protocol":1}
```

The app reads only the fields it knows. A guest ignores any port it does not
know about. Either side can therefore be updated first.

## Device access, SSH, language and input

- The user-facing ports (audio, clipboard, camera, settings) and the camera
  loopback device carry `TAG+="uaccess"`. logind grants them to whoever holds
  the active session. Omarchy's owner provisioning does not add the owner to
  `audio`, `video` or `users`. Audio, camera and clipboard bridges follow
  `graphical-session.target`, so provisioning and SSH user managers do not
  compete with the desktop for the host ports. Package upgrades move enabled
  global audio and camera units to that target, preserving disabled units.
- With SSH forwarded, `try-omarchy-ssh-access` starts sshd for that boot. It
  also allows port 22 through Omarchy's ufw firewall: from the NAT gateway
  `10.0.2.2`, or from anywhere when the VM is bridged
  (`tryomarchy.ssh_from=any`). It removes the rule again on boots without
  SSH.
- `try-omarchy-locale` sets `LANG` from the Mac's language while Omarchy's
  owner provisioning is pending, on first boot or after Omarchy's factory
  reset. It generates the locale first.
- Omarchy chooses the input method itself. On a Mac JIS keyboard,
  `try-omarchy-input-init` maps かな/英数 to input method on/off once per
  user; see [Japanese input](../../docs/japanese-input.md).

## Time zone

`try-omarchy-timezone.service` follows the Mac's time zone. Omarchy's setup
form lists `timedatectl list-timezones` and preselects `tzupdate -p`; the
package's stand-ins for both in `/usr/lib/try-omarchy/shims`, on the setup
service's `PATH` only, put **Same as macOS** first and preselect it, and send
the choice to `try-omarchy-timezone --select`. **Same as macOS** follows the
Mac; a named zone, there or later, is a fixed choice.

The package's menu extension changes the action of Omarchy's **Timezone**
row (`update.timezone`). It opens `try-omarchy-timezone-menu`:
Omarchy's zone list with **Same as macOS** first, which turns following back
on. A sudoers rule lets that picker run `try-omarchy-timezone --follow-mac`
or `--select <zone>` without a password, as Omarchy's own rule does for
`timedatectl set-timezone`.

## Ghostty

Ghostty needs desktop OpenGL 4.3; VirGL here offers OpenGL ES 3.0, so the
stock package exits at startup. `/usr/lib/try-omarchy/bin/ghostty` runs it with
`LIBGL_ALWAYS_SOFTWARE=1`. `/etc/profile.d/try-omarchy.sh` puts that
directory first on `PATH` (Omarchy's session takes `PATH` from the login
shell), and the session's `environment.d` puts `/usr/share/try-omarchy/xdg`
first in `XDG_DATA_DIRS`, whose Ghostty desktop entry calls the wrapper. Pacman
hooks keep that entry linked only while Ghostty is installed, since Omarchy's
launcher ignores `TryExec`. A
user-unit drop-in covers D-Bus activation and starts the unit as `Type=dbus`:
Ghostty 1.3.1's `notify-reload` unit fails under systemd 262. The wrapper
sets `LIBGL_ALWAYS_SOFTWARE=0` for programs started in Ghostty, so they keep
the GPU. See [Ghostty](../../docs/ghostty.md).

Kitty creates a GL context on VirGL but its window stays empty, so
`/usr/lib/try-omarchy/bin/kitty` runs it on the software renderer the same
way, found on the same `PATH` (Kitty's desktop entries run `kitty` by name).
It passes `-o env=LIBGL_ALWAYS_SOFTWARE`, which leaves the variable empty,
and so false, for programs started in Kitty.

## Project wallpaper

The project wallpaper ships in `/usr/share/try-omarchy/backgrounds/tokyo-night/`.
`user-setup` links each file there into the user's
`~/.config/omarchy/backgrounds/<theme>/` once, where Omarchy's background
switcher offers it beside the theme's own backgrounds. Omarchy's default and
current background stay as they are, and a link the user removes stays
removed.

## Boot console

`/etc/limine-entry-tool.d/50-try-omarchy-console.conf` adds `console=hvc0`
and repeats `console=tty0`, so the screen stays `/dev/console`. Kernel and
boot messages then also reach the VM's virtio console, which the app keeps as
`console.log`. It takes effect when Limine's entries are next rebuilt, which
the factory build does and every kernel update does.

`/etc/limine-entry-tool.d/50-try-omarchy-cpu.conf` adds `arm64.nosme`. The
M4 reports SME without SVE, and QEMU under HVF cannot hide SME, so programs
that run an SVE instruction outside streaming mode crash with SIGILL. Chips
before the M4 have no SME. It takes effect the same way as the console, and
the upgrade that adds it also rebuilds Limine's entries once on a guest that
still shows SME, so existing M4 VMs pick it up at their next boot.

## Hyprland

Omarchy has no system-wide Hyprland drop-in directory. At the owner's first
provisioning and at every graphical login, `user-setup` places one loader at
`~/.local/state/omarchy/toggles/hypr/zz-try-omarchy.lua`. Omarchy loads that
directory after the user's own configuration on every reload. The loader runs
`/usr/share/try-omarchy/hyprland.lua`, which the package owns. That file
hides the guest cursor (Cocoa draws the Mac's) and hides it again whenever a
window closes, since Omarchy's screensaver shows it as it exits. It also keeps
the mode in sync with the window through EDID, and applies the pinch and Apple
keyboard input rules.

## Draft HDR integration

This branch adds a source-built Hyprland companion archive as package-owned
data and Linux 7.2.8 HDR virtio GPU sources for DKMS. The normal factory and
pre-login integration update invoke `hdr-install` outside pacman's install
hooks. The compositor is installed through pacman, preserving its package
ownership and dependency checks. See the [HDR build contract](../../docs/native-opengl-hdr-build.md)
for supported versions, restart requirements and the explicit HDR launch opt-in.
Storage and previous-VM import are unchanged from upstream.
