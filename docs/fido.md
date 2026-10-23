# USB FIDO keys

The experimental FIDO bridge gives one explicitly selected USB FIDO interface to one Try Omarchy VM. It is off unless `OMARCHY_QEMU_GPU_FIDO_DEVICE` names an interface from the helper's discovery command. Discovery uses the USB transport, FIDO usage page `0xf1d0`, usage `1`, and a validated HID descriptor. The bridge supports unnumbered 64-byte input and output reports. Other layouts are listed as unsupported and are never opened.

The selector is an IORegistry entry ID, not a vendor or product filter. A missing selection fails without choosing another key, even if an identical model is attached. Replugging a key requires selecting its new ID. FIDO forwarding and experimental whole-device USB passthrough cannot be enabled together in this first version.

## Ownership and transport

The host bridge runs as the Mac user and exclusively opens only the selected FIDO interface. The Mac cannot use that FIDO interface while forwarding owns it. The bridge does not forward OTP, smart-card or other interfaces, and makes no simultaneous-use promise for them. The opted-in guest can send FIDO commands; the bridge does not restrict access to a browser or interpret relying-party consent.

The launcher adds `dev.tryomarchy.fido.v2` only for an explicit selection. Its host endpoint is a private Unix socket in the existing owned per-run directory. The bridge uses the existing QEMU process identity and optional-bridge supervision. It creates no TCP listener or shared pairing secret.

The guest helper opens the root-only virtio port and `/dev/uhid`, creates one temporary FIDO device, and permanently drops supplementary groups, GID and UID to `nobody` before handling the host stream. A device-specific udev rule grants the virtual hidraw device to the active local session. The package does not widen access to `/dev/uhid`. Closing the retained UHID descriptor destroys the virtual device.

Upgrades from before `0.1.0-36` reload the unit definition and replace an enabled helper with the installed version. The preset applies only when the unit was absent on an upgrade from before `0.1.0-35`. Existing units retain their enabled, disabled or masked choice. Other states are stopped without being enabled, and later upgrades leave that state alone. The service skips startup when the app exposes no version-2 port.

## Protocol 2

Each record starts with `0x7e` and ends with `0x7f`. Inside a record, bytes `0x7d`, `0x7e` and `0x7f` are escaped as `0x7d` followed by the byte XOR `0x20`. A new start marker discards any unfinished record, including a pending escape. Bytes outside records are discarded while waiting for the next start marker; they do not renew a lease. A marker can never occur unescaped in report data.

The decoded frame has an eight-byte header: ASCII `TOFD`, version `2`, a one-byte kind, and a two-byte unsigned big-endian payload length. Report frames carry exactly 64 bytes. Hello and ready carry the same fresh 16-byte guest nonce; other kinds have an empty payload. Unknown versions, kinds, lengths and escapes end the session. Decoded storage is limited to one 72-byte frame, and transport reads to 4 KiB.

| Kind | Direction | Meaning |
| --- | --- | --- |
| 1 | Guest to host | Hello with a fresh nonce; the host may acquire the selected interface |
| 2 | Host to guest | Ready with the matching nonce; report forwarding may begin |
| 3 | Both | One unnumbered HID report |
| 4 | Guest to host | Lease heartbeat |
| 5 | Host to guest | Heartbeat reply |
| 6 | Both | Release the session |

The nonce identifies a handshake, not permission to use the key. Permission comes from the private endpoint and explicit device selection. Before ready, the guest ignores stale reports, lease replies, release messages and ready replies for another nonce. It neither injects them into UHID nor extends the handshake deadline. Wrong-direction messages still fail. A duplicate ready after negotiation also fails.

The initial handshake has a 30-second timeout. After negotiation, the guest sends a heartbeat every two seconds and both sides require peer activity within ten seconds. Queues are limited to 16 KiB. A missing or incompatible guest never authorizes opening a physical key.

Temporary guest-port read and write errors retain the virtual device, partial frame and queued bytes for a later retry. Retries do not extend the handshake or lease deadline. A disconnected port, malformed frame, expired lease or full queue still ends the session.

Protocol 1 experimental builds use a different port, `dev.tryomarchy.fido`. The version-2 host and guest use only `dev.tryomarchy.fido.v2`, so neither mixed-version pair sends a greeting into the other protocol’s channel. There is no fallback to the vulnerable framing. Use the matching app and guest package (`0.1.0-35` or newer for protocol 2), then restart the VM. A package-only upgrade requests replacement of an enabled old guest helper; with an old app, the new unit skips startup because its version-2 port is absent. Already-running legacy code has no new parser guarantees until stopped or restarted. A mismatch affects this optional bridge, not the VM or other integrations.

Shutdown, peer failure, lease expiry, device removal and Mac sleep end the host lease. Before closing the interface, the host attempts CTAPHID cancellation for outstanding CBOR requests and channel resynchronization for outstanding requests. This cleanup is best effort; physical-key recovery still needs hardware acceptance. Reconnects must negotiate again and can only acquire the same selected registry entry. The existing launcher limits host helper restarts; failure remains local to FIDO forwarding.

When the guest helper stops or fails, it closes the virtual device and transport without flushing queued reports or appending a release record. If guest port closure does not disconnect the host socket, the restarted helper starts a new hello record. That boundary discards an unfinished report. An already-negotiated host rejects the new hello, closes the socket and releases the old lease. The supervisors then retry with a new host connection and guest handshake; no reader is reset merely on an assumed guest-side disconnect. The guest nonce prevents buffered ready replies from activating the replacement guest.

If the guest stops without restarting, the host lease bounds release after the last complete guest message. Host shutdown likewise does not flush partially transmitted reports; a new host record boundary cannot finish an earlier partial record in the guest.

## Acceptance

Synthetic tests cover descriptor and exact-device selection, fragmented and malformed frames, queue limits, negotiation before acquisition, control messages, guest privilege-drop ordering, pending-response cleanup and device release. These checks do not establish physical touch, browser or kernel behavior.

The `make test-fido-simulated` target runs the focused suites without a key or VM. See [the generated cases and their limits](fido-simulated-tests.md).

Before upstream submission, run `make test` and `make e2e`, then record this matrix using disposable test credentials and a disposable VM:

- Register and authenticate in the guest browser with the original key and at least one other vendor. Include normal touch and PIN flows.
- Cancel a browser request while the key awaits touch. Let another request time out. Verify another request succeeds afterward.
- Unplug during a request, reconnect, and explicitly select the new registry ID. Verify an identical unselected key is never acquired.
- Stop the guest service, kill each helper, and quit the guest. Verify the virtual device disappears and host FIDO authentication succeeds after release.
- For guest-service stop, measure physical-interface release against the ten-second lease plus a two-second observation allowance. Confirm that allowance on the target builds.
- Close the Mac lid during an idle session and during a pending request, then wake it. Verify release, bounded recovery and normal host use.
- Try concurrent Mac FIDO access while the VM owns the interface. Verify the documented exclusive behavior and host recovery afterward.
- Test app-before-package and package-before-app updates, malformed peer input, a missing key and an unsupported descriptor. The VM must remain usable.

See [the user guide](../manual/security-key.md), [integration updates](integration-updates.md), the [FIDO HID specification](https://fidoalliance.org/specs/fido-v2.3-ps-20260226/fido-client-to-authenticator-protocol-v2.3-ps-20260226.html#usb-hid), and [Linux UHID](https://docs.kernel.org/hid/uhid.html).
