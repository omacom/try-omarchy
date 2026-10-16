# Ghostty on ARM64

Ghostty is an ordinary Omarchy package on ARM. Omarchy's `edge` repository
for `aarch64` carries `ghostty`, and **Install → Terminal → Ghostty** in the
Omarchy menu installs it the same way it does on any other machine. Updates
arrive with `omarchy update`.

Ghostty requires desktop OpenGL 4.3. The VM's VirGL renderer offers desktop
OpenGL 4.1 (core and compatibility) and OpenGL ES 3.0 on the Mac's GPU, so a
4.3 context fails and the stock package exits as soon as it starts: the
terminal opens and closes. Mesa's software renderer offers OpenGL 4.6. The `try-omarchy` package runs Ghostty on Mesa's software renderer
(`LIBGL_ALWAYS_SOFTWARE=1`) without changing Ghostty's files:

- `/usr/lib/try-omarchy/bin/ghostty` sets the variable and runs
  `/usr/bin/ghostty`. `/etc/profile.d/try-omarchy.sh` puts that directory
  first on `PATH`, for launches by name such as Omarchy's screensaver.
  Omarchy's session takes `PATH` from the login shell; one set in
  `environment.d` is replaced.
- `/usr/share/try-omarchy/xdg/applications/com.mitchellh.ghostty.desktop`
  shadows the package's desktop entry, through `XDG_DATA_DIRS`, and calls the
  wrapper. Omarchy's terminal launcher (`xdg-terminal-exec`) uses it. It is a
  link to `/usr/share/try-omarchy/ghostty/`, present only while Ghostty is
  installed: Omarchy's app launcher ignores `TryExec`, so an entry for a
  missing Ghostty would be listed and fail. Pacman hooks
  (`/usr/share/libalpm/hooks/try-omarchy-ghostty*.hook`) run
  `ghostty-desktop-entry` when Ghostty or `try-omarchy` is installed,
  upgraded or removed.
- A drop-in for `app-com.mitchellh.ghostty.service` starts the wrapper for
  D-Bus activation. It also makes the unit `Type=dbus`: Ghostty 1.3.1's
  `notify-reload` unit fails under systemd 262 ("lacks handler for reload
  signal USR2, refusing service startup"), stock binary included, on any
  Omarchy machine with that systemd. Omarchy reloads Ghostty with `SIGUSR2`
  directly, which still works.

Only Ghostty renders in software. The wrapper also passes
`--env=LIBGL_ALWAYS_SOFTWARE=0`, which Mesa reads as false, so shells and
programs started in a Ghostty terminal keep the GPU. Ghostty's `env` option
can override an inherited variable but not remove it; a program that treats
the variable's mere presence as "software" would still see it. Software
rendering costs more CPU, especially at high resolutions. The `PATH` and
`XDG_DATA_DIRS` changes apply from the next login.

Verified on 2026-10-16 in a guest with `try-omarchy 0.1.0-14`, Ghostty
1.3.1, Mesa 26.2.4 and systemd 262: a launch through `xdg-terminal-exec` (as
**Super + Return** does) and a D-Bus activation each opened a Ghostty window
that stayed open, rendering on llvmpipe, and the shell inside saw
`LIBGL_ALWAYS_SOFTWARE=0`. A login shell resolves `ghostty` to the wrapper;
the desktop session's `PATH` after a fresh login is not yet confirmed.

Try Omarchy no longer ships its own Ghostty installer or source build;
earlier versions needed them because the pinned guest had no ARM Ghostty
package.

Upstream references: [Ghostty](https://ghostty.org/docs) and
[omarchy-pkgs](https://github.com/omacom/omarchy-pkgs).
