# Reviewed boot-migration inputs

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

The app's fix manifest covers these inputs, the runner, component planners,
user planner, and exact integration bundle. Add future repairs only with their
reviewed preimages, destination allowlist, dependencies, journal recovery, and
per-component result. Package/kernel updates and biometric enablement are
separate workflows.
