# Reviewed boot-migration inputs

`catalog.json` is the shared source for the app's review list, component names,
icons, and optional notes. Each ordered migration has a stable `id`, positive
integer `revision`, short `title`, and SF Symbol `icon`. Optional `group` values
refer to the catalog's named presentation groups; results still identify each
component separately. Optional `note` values explain a component's requirements.
Catalog IDs name existing Python planners; the catalog cannot name commands or
load executable paths.

Packaging and runtime validate that the catalog contains each implemented
component exactly once. The catalog is copied into the settings payload and
hashed by `fixes.json`, so metadata changes are covered by the same whole-bundle
consent as the repair code. Revisions describe changes to a component; they are
not a per-VM migration ledger and do not filter the review. The app lists all
supported repairs, and the guest checks which ones are needed at boot.

`omarchy-lock-password` is the password-policy heredoc from `bin/omarchy-apply-lock`
at the pinned upstream commit `c668141e9c42b13c80c9ca4ea108e11708c5e8a5`.
The migration seeds a missing policy only; it preserves existing password and
fingerprint policies, account passwords, sudo PAM, and Touch ID enrollment.

`preimages.json` records SHA-256 contents of the project's historical stock
integration files from their committed source history. It grants replacement
only at the corresponding fixed destination, never permission to execute a
command or modify another path. Battery binary eligibility additionally checks
the known module versions and the supported DKMS location. Enrolled older
authentication protocols remain subject to explicit guest review.

`omarchy-install-service-1password` is the reviewed ARM64 installer postimage
from `spec.json`; packaging checks its digest against the factory backport.
The `onepassword-installer` migration replaces the old stock installer from
before commit `658fd42`, including the exact temporary workaround that changed
only `/usr/share/applications/1password.desktop` to
`/usr/share/applications/com.onepassword.OnePassword.desktop`. Missing,
customized, or unsafe installers are skipped. It does not install 1Password or
enable its optional Touch ID integration. After an interrupted installation,
rerun **Install → Service → 1Password** to complete application setup.

The `ghostty` migration recognizes the generated installer pins first shipped
in commit `d56a3c0`, alongside the stock recipes. The
`tests/fixtures/ghostty-build-spec-before-system-fontconfig.json` fixture is the
sorted JSON `supplyChain.ghostty` subset from that commit's `spec.json`, with a
trailing newline, as written by the payload builder. This lets revision 2 update
VMs that already received revision 1 while preserving customized pins.

The app's fix manifest covers these inputs, the runner, component planners,
user planner, and exact integration bundle. Add future repairs only with their
reviewed preimages, destination allowlist, dependencies, journal recovery, and
per-component result. Package/kernel updates and biometric enablement are
separate workflows.

`japanese-input` installs the Apple keyboard overlay only with existing
Fcitx5/Mozc dependencies. Its older overlay preimage is from `fc108341`.
`japanese-input/profile-chewing.ini` and `profile-korean.ini` are the exact
factory seeds from `c6c2cc0` and `3e9f720`. The user planner recognizes their INI
values and the current seed, including Fcitx's saved DefaultIM and Korean-first
GroupOrder, while rejecting additional settings and custom engine lists.
It adds Mozc without changing the direct-input keyboard or selected group.
JIS hotkeys are seeded only when global config is missing; explicit Hyprland
models and existing shortcuts are preserved. All home changes run as the owner
and share the user transaction journal, including one entry when pinch and
keyboard overlays both extend `input.lua`. It does not install packages, change
locale, or enable a disabled input-method service.

The `shell-qtquick` migration pins stock shell QML imports to `QtQuick 6.11`.
Qt 6.12 adds a `Color` singleton that shadows Omarchy's palette.
This ports the import workaround from [upstream PR #14845](https://github.com/omacom/omarchy/pull/14845)
without requiring the newer Quickshell load-patch support.
The factory delivers the same edit through the `shell-qtquick-611` backport.

`python3 guest/scripts/generate-shell-qtquick-backport.py --source SOURCE`, run
from the repository root, verifies the pinned
upstream source digest and applies all prior factory backports before generating
the patch, hashes, destination allowlist, and compressed QML test fixture.
The fixture contains the 102 affected QML files before this backport.
Its tar entries have fixed metadata, and its gzip timestamp is zero.
Migration preimages include the pinned stock files, intermediate notification
backports, and reviewed power-menu revisions.

The boot runner preserves unknown files and unsafe destinations.
It reports `current` for the same stock files repaired by hand with the plain
`import QtQuick` to `import QtQuick 6.11` line rewrite.
It repairs recognized files again after runtime package reinstallation.
Power-menu and import changes share one journal entry per destination.
The shell component reports `applied` when it repairs any eligible files, even
if other files are preserved. It reports `preserved` when only unknown files remain.

When extending a migration:

- Keep its stable catalog ID and increase its revision when its repair changes.
  Update its title, icon, group, or note when the user-facing description changes.
- For a new component, implement its named planner and register it in
  `HANDLED_COMPONENTS` before adding its catalog entry. Include the exact payload
  files, allowed destinations, dependency checks, and any service activation and
  recovery handling. Updating a factory file alone does not add a migration.
- Review and record older stock-file hashes in `preimages.json` or the relevant
  planner's strict preimage checks. Preserve customized and unsupported files.
- Test skip/consent, repeat application, preserved customizations, failed writes,
  and interrupted recovery. Catalog validation and manifest binding are covered
  by `tests/test_boot_fix_catalog.py`; use `make test` for the complete suite.
