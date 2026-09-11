# Existing VM integration updates

Status: implemented on the integrated installer branches; review and release gates below.

The app bundles a reviewed integration payload independently of the factory disk.
A dedicated read-only 9p share (tryomarchy-updates) exposes it to old guests.
Users approve the first mount/install inside the guest with their Linux password.
No SSH, personal folder sharing, disk mutation from macOS, or typed-command
injection is required. The launcher offers the exact bootstrap command to copy.

A root-owned guest service reports bounded JSON over a dedicated virtio port.
The host checks on every boot, retains last-known status alongside that VM's disk,
and distinguishes waiting, no response, updates available, and reported current.
Guest messages are advisory: they cannot select host paths or execute host code.
An absent response does not prove absence of the bootstrap. Installations remain
explicitly approved; biometric enrollment is never automatic.

Versioned migrations cover sudo support, clock recovery, compatibility holds,
and an optional per-user 1Password setup. A root-owned installed bundle and root-private
journal support verification and retry after interrupted installation. Existing
configuration and service backups are retained. User modifications to managed
files require review instead of silent replacement. Kernel and graphics package
replacement are excluded.

Validation must cover an old guest with no agent, current/older/newer agents,
malformed/oversized status, interrupted and repeated updates, per-VM state,
customized files, disabled optional features, and an actual old-guest bootstrap.

## Implemented user journey

The launcher has a VM integrations row even before bootstrap. Review opens
instructions and a Copy setup command button. It mounts only the app's dedicated
read-only bundle and starts a guest terminal guide. The guide inventories the
base integrations and offers a separate 1Password action. Linux sudo authorization
occurs only after the review confirmation. sudo biometric pairing remains a
separate explicit action.

A live status menu appears on macOS while QEMU runs. It starts at Checking and
receives guest reports every ten seconds. At 120 seconds without a report it
shows Setup or repair needed; it continues listening for a late boot or repair.
The persisted result is labeled Last check in the launcher. Guest time is never
used to determine freshness. State lives at the VM storage root, keyed by the working disk's file identity,
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

Validated in a disposable guest with the bootstrap disabled and compatibility
holds removed: automatic missing-agent detection, read-only bundle mounting,
base installation, preservation of custom menu entries, repeated installation,
and fresh current status after a VM restart. This fixture models an older guest;
it is not a substitute for testing every historical factory release. It uses a
test-only sudo policy, so interactive password authorization remains a manual
check. Optional 1Password authorization requires a configured account and remains
a manual release gate.

The native application builds and passes signature and compatibility checks.
A fresh factory build remains blocked by rolling package repositories diverging
from the reviewed package lock. No package versions were changed for this feature.
The tested application uses a previously completed factory artifact and the new
integration bundle. Rebuild the factory from the final source before release.

This change currently builds on the integration branches for 1Password, clock
recovery, compatibility-hold repair, and launcher layout. Review its own commit
against the integration baseline; resolve those dependencies before submitting a
standalone upstream change.
