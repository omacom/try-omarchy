# Simulated FIDO coverage

The `test-fido-simulated` Make target runs the host and guest FIDO unit suites without a physical key or VM. The host tests use fake report devices and local socket pairs. The guest tests replace kernel I/O with test data.

The generated corpus uses seed `0xf1d020261021`. The Swift generator and Python generator have different algorithms. Both implementations also use the same 13 literal wire vectors in [fido-wire-vectors.json](../tests/fixtures/fido-wire-vectors.json).

| Contract | Bounded coverage |
| --- | --- |
| Supported HID descriptors | 648 combinations of input and output field sizes, item widths, saved globals, and physical collection depths |
| Rejected device properties | 198 transport, usage, and report-size mismatches |
| Unsupported or malformed descriptors | 54 rejection cases, with a separate accepted descriptor at the 4096-byte limit |
| Exact interface selection | 896 device lists, including identical names, re-enumeration, unsupported selections, and duplicate IDs |
| Wire compatibility | 13 shared golden vectors on each implementation |
| Transport segmentation | 64 coalesced streams, every split of 16 streams, and 512 seeded chunk sequences on each implementation |
| Invalid headers | 4585 single-byte mutations on each implementation, rejected before payload input |
| Truncated streams | Every prefix of a mixed control/report stream on each implementation, plus the 4096-byte read limit and an oversized-read rejection |
| Host output queue | Every partial drain of an encoded report and heartbeat and three failed appends that preserve the queue |
| Pending responses | 39 sessions across three commands and eight response lengths, with unrelated replies and incomplete sequences |
| Native host lifecycle | Nine no-acquisition cases, 11 acquired-session failures, three stop paths, and one successful report round trip |
| Guest relay | Five rejected direction cases and eight valid streams containing 36 reports |
| Guest UHID output | 128 accepted normalizations, 255 rejected report IDs, 128 rejected sizes, and four rejected report types |
| Guest UHID retries | 14 retry sequences that preserve the complete event, plus a deadline case |

These dimensions overlap. Their counts describe deterministic inputs, not independent trials or reliability rates. The target also retains the earlier FIDO tests, including shutdown framing and package activation regressions. Those regressions are not new simulated-device coverage.

## Scope limits

The pure discovery classifier receives transport, usage, report sizes, and descriptor bytes. It receives no vendor ID or product ID. Descriptor and selection tests exercise that classifier and its fake opener. They do not emulate IOKit discovery or prove that another vendor's physical interface exposes the expected properties.

The native overflow case fills the output queue through fake device callbacks before the next socket write. It checks queue bounds and release. It does not force the kernel socket send buffer to stall or test a blocking IOKit operation.

Numbered reports, extended usages that embed their usage page, and descriptors with unrelated report collections remain unsupported by this implementation. A rejected legitimate layout is not a malformed device. These tests do not broaden the supported contract.

No test authenticates to a relying party or checks key firmware. Mac interface acquisition, physical release, touch, PIN prompts, cancellation recovery, unplug behavior, and sleep or wake still require target hardware. Another vendor remains untested until a different physical key is used. NFC and Bluetooth are outside this USB interface bridge.

The narrow target does not run the full repository suite or E2E. It does not establish release readiness. See [the FIDO bridge design and acceptance matrix](fido.md).

Protocol 2 also checks every incomplete escaped-report prefix against every split of a replacement greeting, reserved bytes across all 256 HID byte values, host-channel teardown and fresh negotiation, stale ready/report handling in the guest, duplicate ready rejection, and both protocol-1 incompatibility directions. These are codec, fake-device and socket controls; they do not establish live virtio-kernel timing or physical-key recovery.
