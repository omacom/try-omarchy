# Ghostty on ARM64

Ghostty is an ordinary Omarchy package on ARM. Omarchy's `edge` repository
for `aarch64` carries `ghostty`, and **Install → Terminal → Ghostty** in the
Omarchy menu installs it the same way it does on any other machine. Updates
arrive with `omarchy update`.

Ghostty requires desktop OpenGL 4.3. The VM's VirGL renderer offers OpenGL ES
3.0, so the stock package exits as soon as it starts: the terminal opens and
closes. The `try-omarchy` package runs Ghostty on Mesa's software renderer
(`LIBGL_ALWAYS_SOFTWARE=1`) without changing Ghostty's files:

- `/usr/lib/try-omarchy/bin/ghostty` sets the variable and runs
  `/usr/bin/ghostty`. The session's `environment.d` puts that directory first
  on `PATH`, for launches by name such as Omarchy's screensaver.
- `/usr/share/try-omarchy/xdg/applications/com.mitchellh.ghostty.desktop`
  shadows the package's desktop entry, through `XDG_DATA_DIRS`, and calls the
  wrapper. Omarchy's terminal launcher (`xdg-terminal-exec`) uses it.
- A drop-in for `app-com.mitchellh.ghostty.service` sets the variable for
  D-Bus activation.

The variable is inherited by programs started from a Ghostty terminal, which
then also render in software. Software rendering costs more CPU, especially at
high resolutions. The `PATH` and `XDG_DATA_DIRS` changes apply from the next
login.

Not yet verified in a running guest. To check, install Ghostty, restart the
VM, press **Super + Return**, and confirm a Ghostty window stays open. If it
still closes, choose another terminal in the Omarchy menu and run `ghostty`
from it to see the error.

Try Omarchy no longer ships its own Ghostty installer or source build;
earlier versions needed them because the pinned guest had no ARM Ghostty
package.

Upstream references: [Ghostty](https://ghostty.org/docs) and
[omarchy-pkgs](https://github.com/omacom/omarchy-pkgs).
