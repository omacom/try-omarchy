# Existing VM integration updates

Status: standalone integration delivery on current upstream; the payload is sudo Touch ID support and the Mac battery mirror.

The Mac launcher also has a separate consent-gated boot-file migration path.
It reuses the existing settings boot payload and settings status port for exact
stock repairs, integration bootstrap/support, and eligible battery migration.
It plans the reviewed destinations directly; it does not invoke arbitrary shell
installers. Battery kbuild staging precedes the file journal and publishes the
verified module with DKMS receipts. Authentication enrollment remains separate. The review, Skip
confirmation, disk/bundle-bound consent, durable file journal, interrupted
recovery, and per-fix results are documented in
[integration updates](../docs/integration-updates.md#updates-at-launch).

The app bundles a reviewed integration payload independently of the factory disk.
A dedicated read-only 9p share (tryomarchy-updates) exposes it to old guests.
Normal supported bootstrap is handled by **Update and Launch**. The manual
fallback still lets users approve mount/install with their Linux password.
No SSH, personal folder sharing, disk mutation from macOS, or typed-command
injection is required. The integration-update documentation supplies the exact
bootstrap command for manual fallback.

A root-owned guest service reports bounded JSON over a dedicated virtio port.
The host checks on every boot, retains last-known status alongside that VM's disk,
and distinguishes waiting, no response, updates available, and reported current.
Guest messages are advisory: they cannot select host paths or execute host code.
An absent response does not prove absence of the bootstrap. Installations remain
explicitly approved; biometric enrollment is never automatic.

The initial migration installs upstream sudo Touch ID support. Pending 1Password,
clock-recovery, and package-hold repair features are excluded. A root-owned installed bundle and root-private
journal support verification and retry after interrupted installation. Existing
configuration and service backups are retained. User modifications to managed
files require review instead of silent replacement. Kernel and graphics package
replacement are excluded.

Validation must cover an old guest with no agent, current/older/newer agents,
malformed/oversized status, interrupted and repeated updates, per-VM state,
customized files, disabled optional features, and an actual old-guest bootstrap.

## Implemented user journey

The launcher offers **Update** when the selected disk needs a check against the
current boot-fix bundle. **Update and Launch** applies eligible repairs before
login and reports per-component results in Settings. There is no separate
manual-install banner or menu-bar prompt.

The guest guide inventories support, directs routine updates to the launcher,
and offers optional sudo Touch ID pairing/testing and a labeled manual repair
fallback. The fallback mounts only the app's dedicated read-only bundle.
Linux sudo authorization occurs only after the manual review confirmation.
Biometric pairing remains a separate explicit action.

The host checks silently while QEMU runs and receives guest reports every ten
seconds. After 120 seconds without a report it records no response and continues
listening for a late boot or repair. These advisory reports do not open UI or
authorize installation. Guest time is never used to determine freshness.
State lives at the VM storage root, keyed by the working disk's file identity,
so reset and alternate VM locations do not inherit another VM's result. The
strict disk-directory inventory remains unchanged.

Bundle identity covers the exact payload inventory and hashes. The app signature
covers the distributed manifest and files. Hash checking detects corruption; it
is not a substitute for trusting the app supplying the bundle. Guest sudo is an
explicit approval to install that app's code. The status channel cannot request
installation or host actions.

Progress is committed after each verified migration; retries skip completed,
still-healthy steps. Partial failures are reported and retain backups. This is
resumable installation, not a claim of transactional rollback of arbitrary
systemd/PAM effects. The old bundle is retained when the installed bundle changes.

## Validation and release gates

Validate old-guest bootstrap, cancellation, installation, interrupted retry,
configuration and enrollment preservation, and status after a restart. Verify
that the initial bundle contains only installers and support accepted upstream.
Factory package-lock changes are outside this PR. Fresh-image generation uses
that same bundle, so its first report must match the bundled identity.

Build and test the current branch, and distinguish a clean source build from
app packaging that reuses a released guest or runtime. Biometric enrollment and
actual authorization are separate from installing support and remain explicit
user actions; a report of current files does not prove an authorized Touch ID use.
