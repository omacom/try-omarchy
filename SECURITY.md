# Security policy

Please do not file a public issue for a suspected vulnerability. Use GitHub's
private vulnerability reporting or security-advisory flow for this repository
and include reproduction steps, affected versions, and the expected impact.

Only the current `main` branch is supported before the first stable release.
Security-sensitive areas include downloaded build inputs, artifact and manifest
validation, code signing, VM disk handling, the QEMU process boundary, the host
settings and package the app passes to the guest, and the guest-to-host
bridges (audio, clipboard, camera, battery, Touch ID, settings and status).

The project will acknowledge a complete report as soon as practical, assess its
scope, and coordinate a fix and disclosure with the reporter.
