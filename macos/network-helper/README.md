# Bridged networking runtime

The `vendor` directory contains socket_vmnet v1.2.2 from
https://github.com/lima-vm/socket_vmnet, commit
7160c755b3c298f02d8d5d1f1290c4d69a6f26fd. Its Apache-2.0 license is in
`vendor/LICENSE`. Only its server sources are bundled; QEMU connects using its
existing Unix stream backend. Build with `bash build.sh OUTPUT_DIRECTORY`.

The app registers `dev.tryomarchy.network` with `SMAppService`. macOS approves
this launch daemon once; it starts on demand for privileged XPC requests.
The service remains registered until removed through the networking sheet.
QEMU and the app remain unprivileged. Repair or removal interrupts an active
bridged session, so shut the VM down first.

The daemon accepts only the bundled client's exact code-signing hash, embedded
at build time and enforced by XPC. Start requests must come from the active
console user through the app/launcher/client process chain. The service accepts
bounded session parameters, never caller-provided commands or executable paths.
It copies the bundled server and supervisor into a root-owned private directory
and checks their bytes against build-time SHA-256 values before execution.
`build-daemon.sh` runs after those payloads and the client have been signed.
Rebuilding the client changes the accepted identity; use Set Up / Repair
Networking after replacing the app. Local ad-hoc registration is tested;
Developer ID signing, updates, and notarization remain release gates. On the
macOS 27 test host, registering a relocated copy retained the earlier daemon
location even after unregistering; changing app locations is not yet validated.

The per-session supervisor owns the socket helper, restricts socket access to
the launching user, monitors both launcher and application process birth
identities, and restores the previous Wi-Fi setting on stop, owner exit, or
helper failure. Service removal requests the same cleanup. A root-owned lock
serializes this app's bridged sessions. A flushed recovery record allows the
next bridged launch to restore the setting after a forcibly killed supervisor.
Other virtualization apps do not participate in this lock. Wi-Fi compatibility
is selected automatically when the host exposes its control; the networking
sheet explains that it affects all host bridges while enabled.

Local changes to the vendored server handle partial stream reads and writes,
retry interrupted calls, and reject invalid Ethernet frame lengths instead of
asserting. `vendor/stream.h` contains the added framing helpers.

For isolated development builds, set `OMARCHY_NETWORK_SERVICE_NAME` to a distinct
reverse-DNS name when running `macos/build-app.sh`. The build uses the same value
for the launch-daemon label, Mach service, client, and daemon. The default is
`dev.tryomarchy.network`. A separate name prevents test copies from sharing the
normal app's Service Management registration; it does not validate upgrades or
relocation of an existing registration.

## Ethernet adapter reconnection

The bridge server watches the selected interface once per second, including its
link state and kernel interface index. Removing a dock invalidates the old
vmnet attachment even if the returning interface keeps the same name. The
server recreates that attachment after two stable observations, preserving the
existing QEMU stream connection and discarding guest packets while disconnected.
Failed starts are retried at five-second intervals. It never selects a different
interface or changes the host's bridge membership directly.

A root-owned atomic `link-state` record carries a monotonically increasing
generation. An unprivileged watcher applies carrier changes through the VM's
private QMP socket; a changed up generation pulses carrier even if the watcher
missed the down record. This lets the guest retry DHCP. Packet callbacks and
writes cannot use an interface after it is detached. Host-to-guest output uses
a bounded 256 KiB per-connection queue and nonblocking writes. Backpressure drops
whole new Ethernet packets while preserving partial stream frames and the socket;
it cannot block vmnet callbacks while the guest boots or its link is down. Framework lifecycle calls
have a ten-second bound; an indeterminate stop/start timeout ends the networking
session rather than creating overlapping interfaces with unknown ownership.

`recovery.test.c` exercises the production stream and lifecycle code against a
fake vmnet provider, including stale callbacks, failed starts/writes, and repeated
recreation. These tests do not substitute for physical dock/cable testing.
