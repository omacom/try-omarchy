# USB FIDO keys

The experimental FIDO bridge gives one explicitly selected USB FIDO interface to one Try Omarchy VM. It is off unless `OMARCHY_QEMU_GPU_FIDO_DEVICE` names an interface from the helper's discovery command. Discovery uses the USB transport, FIDO usage page `0xf1d0`, usage `1`, and a validated HID descriptor. The first protocol supports unnumbered 64-byte input and output reports. Other layouts are listed as unsupported and are never opened.

The selector is an IORegistry entry ID, not a vendor or product filter. A missing selection fails without choosing another key, even if an identical model is attached. Replugging a key requires selecting its new ID. FIDO forwarding and experimental whole-device USB passthrough cannot be enabled together in this first version.

## Ownership and transport

The host bridge runs as the Mac user and exclusively opens only the selected FIDO interface. The Mac cannot use that FIDO interface while forwarding owns it. The bridge does not forward OTP, smart-card or other interfaces, and makes no simultaneous-use promise for them. The opted-in guest can send FIDO commands; the bridge does not restrict access to a browser or interpret relying-party consent.

The launcher adds `dev.tryomarchy.fido` only for an explicit selection. Its host endpoint is a private Unix socket in the existing owned per-run directory. The bridge uses the existing QEMU process identity and optional-bridge supervision. It creates no TCP listener or shared pairing secret.

The guest helper opens the root-only virtio port and `/dev/uhid`, creates one temporary FIDO device, and permanently drops supplementary groups, GID and UID to `nobody` before handling the host stream. A device-specific udev rule grants the virtual hidraw device to the active local session. The package does not widen access to `/dev/uhid`. Closing the retained UHID descriptor destroys the virtual device.

The upgrade that introduces the service applies its preset. Upgrades from before `0.1.0-32` also request a start when the service is enabled, so it can run in the same boot. Disabled and masked services are not started, and later upgrades leave their state alone. The service's port condition skips it when an older app exposes no FIDO channel.

## Protocol 1

Each frame has an eight-byte header: ASCII `TOFD`, version `1`, a one-byte kind, and a two-byte unsigned big-endian payload length. Report frames carry exactly 64 bytes; every other kind has an empty payload. Unknown versions, kinds or lengths end the session before an advertised payload is allocated.

| Kind | Direction | Meaning |
| --- | --- | --- |
| 1 | Guest to host | Hello; the host may now acquire the selected interface |
| 2 | Host to guest | Ready; report forwarding may begin |
| 3 | Both | One unnumbered HID report |
| 4 | Guest to host | Lease heartbeat |
| 5 | Host to guest | Heartbeat reply |
| 6 | Both | Release the session |

The initial handshake has a 30-second timeout. After negotiation, the guest sends a heartbeat every two seconds and both sides require peer activity within ten seconds. Queues are limited to 16 KiB. A missing or incompatible guest never authorizes opening a physical key. An old app exposes no FIDO port, so a new guest package skips the helper. Protocol changes must preserve this independent-update behavior.

Shutdown, peer failure, lease expiry, device removal and Mac sleep end the host lease. Before closing the interface, the host attempts CTAPHID cancellation for outstanding CBOR requests and channel resynchronization for outstanding requests. This cleanup is best effort; physical-key recovery still needs hardware acceptance. Reconnects must negotiate again and can only acquire the same selected registry entry. The existing launcher limits host helper restarts; failure remains local to FIDO forwarding.

When the guest helper stops or fails, it closes the virtual device and transport without flushing queued reports or appending a release frame. A report may have been only partly transmitted, so a release header could be mistaken for its remaining payload. If closing the guest port does not reach the host as a disconnect, the ten-second host lease bounds release after the last guest activity.

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
