# NAT ICMP reply matching on macOS

QEMU's user-mode NAT uses libslirp. On Darwin, an ICMP datagram socket can
receive replies belonging to other pending requests. Previously libslirp
received directly into its saved request, restored that request's identifier,
and forwarded the packet without validating the received identifier, sequence,
or payload. Concurrent ping streams could therefore report duplicate sequence
numbers, unexpected payloads, or invalid latency values.

The bundled libslirp 4.9.4 patch receives into a separate buffer and validates
bounds, checksum, source, identifier, sequence, and echoed payload before
consuming the pending request. Unrelated replies leave the original request
intact. Destination-unreachable and time-exceeded errors match the quoted
request; explicit RFC 4884 quote lengths bound the comparison. Forwarded
fragmentation-needed errors preserve the router's MTU and source address.

This path is Darwin-specific. Its socket API returns the outer IPv4 payload
length and fragment field in host order; quoted IPv4 headers inside ICMP errors
remain in network order. These are not interchangeable representations.

## Reproduce and validate

In a VM using Shared connection (NAT), run concurrent streams to the same
reachable destination. For example:

```sh
ping -n -c 60 -s 56 1.1.1.1 > /tmp/ping-56.log &
ping -n -c 60 -s 57 1.1.1.1 > /tmp/ping-57.log &
ping -n -c 60 -s 1400 1.1.1.1 > /tmp/ping-1400.log &
wait
```

Inspect the individual logs for duplicate replies, unexpected sequence numbers,
wrong-data warnings, and packet loss. An unreachable or rate-limited destination
can lose packets without exhibiting this bug. Verify DNS and HTTPS separately;
echo replies alone do not exercise those paths.

A controlled standalone three-stream reproduction with the original library
returned 58 valid and 122 mismatched replies for 180 requests. The patched
standalone run returned 180 valid replies with no mismatches or duplicates.
A patched VM returned all 180 replies across 56-, 57-, and 1400-byte payloads,
with no malformed replies or duplicates, and passed DNS and HTTPS checks.
One earlier large-payload standalone run missed its first three probes; a
repeat returned all 90. The cause of those three losses was not established.
These observations demonstrate the reproduced defect and fix, not a guarantee
of zero packet loss on arbitrary networks.

## Build and regression coverage

`make runtime` downloads checksum-pinned libslirp and Meson source archives,
applies the checksum-pinned patch, builds against the private pinned GLib, and
runs libslirp's tests before building QEMU. Runtime staging requires the exact
source-built libslirp library and relocates and signs it with the rest of the
runtime. It must not substitute the unpatched bottle during staging.

`make test` compiles the portable matcher regression test embedded in the patch
without downloading libslirp. The complete source build also runs a Darwin
receive-path test using local datagram sockets. That test verifies that an
unrelated reply does not consume or corrupt a request, a subsequent correct
reply is delivered, and a matched MTU error preserves its checksum and metadata.
No Internet connection or privileged packet capture is needed for those tests.

The patch is carried locally by Try Omarchy. Acceptance or release by libslirp
is a separate step; this document does not claim upstream adoption.
