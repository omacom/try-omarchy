# Ghostty on ARM64

Ghostty is an ordinary Omarchy package on ARM. Omarchy's `edge` repository
for `aarch64` carries `ghostty`, and **Install → Terminal → Ghostty** in the
Omarchy menu installs it the same way it does on any other machine. Updates
arrive with `omarchy update`.

Try Omarchy no longer ships its own Ghostty installer, source build or
software-rendering wrapper. Earlier versions of the app needed them because
the pinned guest had no ARM Ghostty package.

Whether Ghostty renders correctly through the VM's VirGL path with the stock
package has not been verified yet. If it does not, `LIBGL_ALWAYS_SOFTWARE=1`
in its launch environment makes it usable at a higher CPU cost.

Upstream references: [Ghostty](https://ghostty.org/docs) and
[omarchy-pkgs](https://github.com/omacom/omarchy-pkgs).
