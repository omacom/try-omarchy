# Third-party notices

Try Omarchy builds and redistributes third-party components under their own
licenses. The repository's MIT license applies only to this project's original
code.

- **Omarchy** — pinned from `basecamp/omarchy`; MIT. Its license is copied into
  every guest artifact as `LICENSE.omarchy`.
- **QEMU** — GPL-2.0 and other component licenses. Release maintainers must
  provide the corresponding source and notices required by the exact bundled
  build.
- **Arch Linux ARM packages** — each package retains its own license. The
  generated package transaction is recorded in `packages.lock.txt`.
- **Hyprland** — BSD-3-Clause; the reviewed v0.56.1 source and rounded-border
  coverage backport are pinned in `guest/spec.json`. The guest package retains
  Hyprland's upstream license and dependency metadata.
- **aquamarine** — BSD-3-Clause; Arch Linux ARM currently publishes only
  `libaquamarine.so=14`, while the pinned Hyprland still requires `.so=13`. The
  factory therefore rebuilds `aquamarine 0.14.0-2` from the reviewed Arch
  PKGBUILD and `hyprwm/aquamarine` v0.14.0 tarball (pinned in `guest/spec.json`)
  for factory builds. The finished guest holds aquamarine and Hyprtoolkit on
  `IgnorePkg` with Hyprland so updates cannot mix incompatible ABIs.
- **Hyprtoolkit** — BSD-3-Clause; the factory rebuilds the reviewed
  `hyprwm/hyprtoolkit` v0.5.4 source using the Arch 0.5.4-6 recipe adapted for
  aarch64 and package release 6.1, linked against aquamarine 0.14. Source,
  recipe, packaging commit, and library hashes are pinned in `guest/spec.json`;
  the package retains its upstream license.
- **Glaze** — MIT; the pinned v7.2.0 headers are used by the Hyprland build, and
  their verified upstream license is retained in the rebuilt guest package.
- **ANGLE, VirGLRenderer, libepoxy, SDL, libslirp, GLib, Pixman, and other QEMU
  dependencies** — retain their respective upstream licenses.
- **mise** — MIT; the reviewed ARM64 release is pinned in `guest/spec.json`.
- **ttfx** — MIT; the reviewed source release and locked Rust dependencies are
  pinned in `guest/spec.json` and built natively for ARM64. Its packaged
  `LICENSE` and `NOTICE` retain attribution to TerminalTextEffects and
  ChrisBuilds.
- **yay** — GPL-3.0-or-later; the official ARM64 release and its versioned
  license are pinned in `guest/spec.json` and packaged into the guest's local
  repository.
- **Voxtype** — MIT; the signed v1.0.1 ARM64 CPU, ONNX, and OSD release assets,
  release key, source archive, and checksums are pinned in `guest/spec.json`.
  They are packaged in the guest's local repository but remain uninstalled
  until the user invokes Omarchy's optional dictation installer.
- **Ghostty** — MIT; optional user-initiated source build. The installer pins
  Ghostty 1.3.1, its Minisign signature and verification key, and the MIT-licensed
  Zig 0.15.2 ARM64 compiler. Ghostty and its bundled dependencies retain their
  upstream licenses; the source archives include the corresponding notices.
  The guest factory image contains only the installer and recipe, not Ghostty
  or the downloaded compiler. These post-build downloads are declared in
  `guest/spec.json` and excluded from factory artifact provenance.
- **1Password** — proprietary software not redistributed by Try Omarchy. When a
  user explicitly invokes its optional ARM64 installer, the guest resolves the
  current vendor release and AUR CLI recipe after the factory build. These
  mutable post-build inputs are excluded from factory provenance and are
  declared separately in `guest/spec.json`; the application archive is accepted
  only when its signature validates to 1Password's pinned signing fingerprint.
- **Vivaldi** — proprietary software not redistributed by Try Omarchy. When a
  user explicitly selects Vivaldi, the guest downloads the exact official ARM64
  RPM pinned in `guest/spec.json`, verifies its checksum and signature against
  Vivaldi's pinned package-composer key, and repackages the verified payload as
  a Pacman-owned local package. The factory image includes the `rpm-tools`
  signature verifier and its locked dependencies; the Vivaldi browser payload
  remains outside the factory image and factory provenance. Vivaldi permits
  open-source Linux distributions to integrate its browser; see
  <https://vivaldi.com/partners/linux/>.

See `guest/spec.json`, `guest/packages.lock.json`, and
`macos/build-qemu-gpu-runtime.sh` for exact source identities and checksums.
Before distributing a release, follow `docs/releasing.md` and audit the assembled
bundle's notices and corresponding-source obligations.

**T3 Code** is an optional, user-initiated download from
<https://github.com/pingdotgg/t3code> (MIT, with Electron/Chromium and bundled
third-party notices). The factory distributes only the Try Omarchy installer.
The installer and Omarchy updater resolve the latest stable ARM64 Electron
AppImage and verify GitHub's asset SHA-256 before packaging it locally. The
application itself is a mutable post-build dependency, not a factory artifact.
