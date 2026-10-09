# Ghostty on ARM64

Choose **Install → Terminal → Ghostty** in the Omarchy menu. The installer
downloads Ghostty 1.3.1 and the ARM64 Zig 0.15.2 compiler, verifies the pinned
SHA-256 digests and Ghostty's Minisign signature, and builds a native package.
Allow several minutes for the first build, an internet connection, and at least
3 GiB free. Compilation uses two jobs and runs as your normal user. Installing
dependencies and the finished package requires your usual system authentication.

This is a source download and local build, not a precompiled ARM64 download.
Ghostty is optional and is not included in the factory image. The source,
compiler, recipe and wrapper pins live in `guest/spec.json`; Zig verifies the
dependency content hashes in Ghostty's build manifest.

After installation, the menu selects Ghostty as the default terminal and keeps
any existing Ghostty configuration. A failed download, verification or build
does not change the terminal preference. Pacman owns the installed files, and
the package is registered in Try Omarchy's local repository so the AUR updater
does not try to replace it. Remove it with `omarchy-pkg-remove ghostty` after selecting another default terminal.
There is no automatic upstream Ghostty release check: a newer pinned release
requires an updated Try Omarchy installer and another installation.

The package leaves `/usr/share/terminfo/g/ghostty` owned by `ncurses` and
includes Ghostty's `xterm-ghostty` entry. Revision `1.3.1-2` fixes the file
conflict that prevented `1.3.1-1` from installing. If you encountered that
failure, apply the VM update described below, then retry the terminal menu.

Revision `1.3.1-3` builds Ghostty against the system fontconfig that GTK
already loads. Earlier revisions bundled a second copy, which could crash open
Ghostty windows when a font was installed or the font cache was rebuilt. To
get this fix on an existing installation, apply the VM update, then choose
**Install → Terminal → Ghostty** again to rebuild the package.

## Existing VMs

In a Try Omarchy app build containing this fix, choose **Update**, then
**Update and Launch**. This installs the corrected Ghostty installer, recipe,
verification pins, and terminal-menu hook on recognized stock VMs. After launch,
choose **Install → Terminal → Ghostty** normally. The VM update does not download,
build, or install Ghostty itself; that remains your explicit menu action.

Customized or unsupported installer files are preserved and reported as skipped.
Existing Ghostty installations, configuration, and your terminal preference are
kept. A skipped or failed VM update leaves the previous installer in place.

For a manual fallback, run inside the guest from a checkout containing this fix:

```sh
./guest/native-overlay/usr/local/lib/try-omarchy/install-ghostty-arm64 --from-checkout "$PWD"
```

This installs the application without changing your default terminal. Launch
`/usr/bin/ghostty` or its application menu entry. To build a package for inspection
without installing it, add `--build-only /path/to/output`; build dependencies
are still installed if missing.

If you previously installed Ghostty manually under `~/.local`, its executable,
desktop entry, D-Bus service or systemd user service may take precedence over
the package. Back up those Ghostty-specific files before removing them; retain
`~/.config/ghostty`. Then run `systemctl --user daemon-reload` and log out and
back in. The installer warns about common local overrides and does not delete
them.

## Rendering and performance

Ghostty needs an OpenGL context that the current Try Omarchy VirGL path cannot
reliably provide. The packaged executable wrapper sets `LIBGL_ALWAYS_SOFTWARE=1`
only when the kernel command line contains `omarchy.qemu_virgl=1`. Desktop,
D-Bus, systemd and command-line launches all use this wrapper. Other guests
retain their existing renderer environment.

This makes Ghostty usable in the VM, but software rendering can consume more
CPU, especially at high resolutions. It does not improve general VM graphics
performance. Alacritty remains the default for newly created guests.

Upstream references: [building Ghostty](https://ghostty.org/docs/install/build),
[Ghostty 1.3.1](https://ghostty.org/docs/install/release-notes/1-3-1), and
[Zig downloads](https://ziglang.org/download/).
