# Third-party notices

Try Omarchy builds and redistributes third-party components under their own
licenses. The repository's MIT license applies only to this project's original
code.

- **Omarchy** — MIT. The factory disk installs Omarchy's own packages
  (`omarchy-dev`, `omarchy-settings-dev` and their dependencies) from
  `pkgs.omarchy.org`; each package carries its license under
  `/usr/share/licenses`.
- **Arch Linux ARM and Omarchy repository packages** — each package retains its
  own license, including Omarchy's `linux-omarchy` kernel (GPL-2.0), Hyprland
  and its libraries (BSD-3-Clause), and Quickshell. The factory's complete
  package set and versions are recorded in `dist/guest/packages.txt`, and the
  `[omarchy]` database digest in `dist/guest/factory.json`.
- **QEMU** — GPL-2.0 and other component licenses. Release maintainers must
  provide the corresponding source and notices required by the exact bundled
  build.
- **edk2 UEFI firmware** — BSD-2-Clause-Patent and the other licenses listed in
  QEMU's `pc-bios/edk2-licenses.txt`, bundled beside the firmware as
  `Contents/Resources/firmware/edk2-licenses.txt`. It is extracted unchanged
  from the pinned QEMU source archive.
- **ANGLE, VirGLRenderer, libepoxy, SDL, libslirp, GLib, Pixman, and other QEMU
  dependencies** — retain their respective upstream licenses.
- **OmacVM** — MIT, Copyright (c) 2026 Gilles Goetsch,
  [github.com/gillesgoetsch/OmacVM](https://github.com/gillesgoetsch/OmacVM).
  The QEMU patches `qemu-hda-no-catch-up`, `qemu-sdl-audio-capture-thread`,
  `qemu-sdl-audio-playback-thread` and `qemu-darwin-main-loop-qos`, and the
  guest's RTKit drop-in, are adapted from OmacVM's; each says so in its
  header. The App Nap patch follows OmacVM's approach.
- **pacstrap-docker** (`guest/vendor/omarchy-pkgs/`) — from
  [omarchy-pkgs](https://github.com/omacom/omarchy-pkgs); used only inside the
  build container.
- **Software users install inside the VM** — packages installed through
  Omarchy's menus or `pacman`, such as Ghostty or 1Password, come from their
  own repositories under their own licenses and are not redistributed by Try
  Omarchy.

See `macos/build-qemu-gpu-runtime.sh` and `macos/stage-uefi-firmware.sh` for
exact host source identities and checksums. Before distributing a release,
follow `docs/releasing.md` and audit the assembled bundle's notices and
corresponding-source obligations.
