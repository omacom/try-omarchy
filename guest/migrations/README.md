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

The app's fix manifest covers these inputs, the runner, component planners,
user planner, and exact integration bundle. Add future repairs only with their
reviewed preimages, destination allowlist, dependencies, journal recovery, and
per-component result. Package/kernel updates and biometric enablement are
separate workflows.

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
