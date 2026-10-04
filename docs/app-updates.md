# Mac app version tracking and updates

The Mac app, its bundled factory image, and an existing guest have separate
versions. Package updates inside the guest do not update the Mac app or QEMU.
Replacing the app preserves the existing VM and its paired boot files; it does
not migrate that VM to the newest factory image.

## Release checks

The first stage of issue #232 provides version display, manual release checks,
and default-on checks on app startup, limited to one attempt per 24 hours. An
explicit opt-out is preserved. Both
successful and failed attempts count toward the limit; manual checks bypass
it. A cached release keeps the update indicator available across launches.
Checks run asynchronously with bounded network timeouts and never invoke VM
shutdown, app replacement, or an installer. A newer known release changes the
launcher link and presents a Download / Skip sheet once per release, when the
launcher or settings are active and idle. Checks finishing during guest use,
launch/reset/shutdown, permission requests, or other dialogs defer presentation.
Both choices suppress further automatic reminders for that version; Skip leaves
the cached update link and manual download available. Network failures remain
quiet. Unknown installed releases and development builds never receive an
automatic update prompt. Reading an available-update result in the manual
Updates window also counts as its notification.

The checker uses GitHub's public `/repos/omacom/try-omarchy/releases/latest`
endpoint without credentials. It accepts published, non-prerelease `vX.Y.Z`
tags with an uploaded `TryOmarchy-vX.Y.Z.dmg` whose version matches the tag,
or the legacy `TryOmarchy.dmg`. Versions compare numerically. The
download action opens the project's release page so the user can read notes
and OS requirements. GitHub release metadata does not declare a structured
minimum macOS version; this stage does not claim compatibility or select an
installer for the host.

Accurate installed-release comparisons depend on the build metadata proposed
in [PR #223](https://github.com/omacom/try-omarchy/pull/223):
`TryOmarchyBuildDescribe` must exactly equal `v` followed by
`CFBundleShortVersionString`. Without that agreement, the checker cannot
identify the installed release and never reports it as up to date. No existing
guest package version is used as a substitute.

## Recommended installation stage

Use [Sparkle 2](https://sparkle-project.org/documentation/) for signed downloads,
verification, replacement, and relaunch. The release checker is an interim
notification feature, not a second installation mechanism. When Sparkle ships,
replace its GitHub transport and preserve the user's automatic-check preference; do not
run two automatic checkers.

Before enabling installation, maintainers need to:

1. Choose a stable HTTPS appcast location and create an Ed25519 signing key in
   their release environment. Embed only the public key in the app. Pin Sparkle
   and integrate framework/helper signing with the existing bundle build.
2. Establish monotonically increasing release build numbers across release
   branches. Verify version stamping and build-cache invalidation together;
   commit counts alone need scrutiny for shallow checkouts and parallel branches.
3. Sign and notarize the completed app, sign the distributable update archive,
   and publish the appcast only after the artifact is available. Encode the
   minimum macOS version and stable channel in the feed.
4. Gate installation on the QEMU supervisor confirming that normal launches,
   recovery boots, and storage operations have all finished. The current app
   termination path forwards SIGTERM, so simply letting Sparkle terminate the
   app is not a clean-shutdown guarantee. Keep installation pending while the
   user shuts the guest down, and prevent a new VM launch during replacement.
5. Test two real signed/notarized builds on a Mac: running guest, cancelled or
   failed shutdown, interrupted download, invalid signature, read-only DMG,
   incompatible OS, and preservation of a VM in a custom storage location.

The first updater-enabled release still requires manual installation. Issue
#232 remains open until the signed installation flow and its acceptance checks
are complete.
