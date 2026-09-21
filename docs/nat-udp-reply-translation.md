# IPv4 UDP reply translation

A guest UDP socket can send to multiple destinations. In libslirp 4.9.4, the socket lookup uses only the guest source endpoint, and each send overwrites the stored foreign endpoint. If a guest sends to the virtual host address and then another address before the first reply arrives, the delayed host-loopback reply can be emitted toward the guest with source 127.0.0.1 instead of the virtual host address.

The IPv4 patch isolates virtual-network and broadcast destinations by remote endpoint while retaining shared mappings for ordinary destinations. Existing UDP host-forwarding sockets retain their handling. Translated destinations can therefore use distinct host source ports; ordinary destinations keep the existing shared-port behavior. IPv6 and UDP ICMP error quotation are outside this change.

## Validation

The automated loopback regression injects guest UDP frames through libslirp, deliberately returns the replies in reverse order, and checks their guest-visible source addresses and payloads. It requires no VM, administrator privileges, or Internet connection. The pinned runtime build compiles and runs it with the existing libslirp suite.

The packet-level reproduction emitted an incorrect source address in all three trials with both original 4.9.4 and the ICMP-only patch; the UDP candidate emitted the correct address in all three trials.

| Live VM check | Before UDP fix | UDP candidate |
|---|---:|---:|
| Overlapping mixed-address UDP replies | 65/100 | 100/100, repeated twice |
| Three UDP controls | 300/300 | 300/300 per pass |
| Concurrent TCP integrity | 8/8 streams | 8/8 streams per pass |

Across the two candidate passes, all 800 UDP responses arrived with correct payloads and source tuples, with no duplicates. UDP payloads ranged from 32 bytes to 8 KiB. Sixteen TCP streams returned 8 MiB with matching hashes and successful half-closes. Concurrent ICMP checks returned 60/60 without duplicate or payload warnings. DNS and HTTPS checks passed. These are bounded test results, not a general Internet packet-loss estimate.

Additional local checks covered both request orders, direct loopback addresses, ordinary source-port sharing, UDP forwarding including an existing outbound socket on the target guest port, DNS alias translation, and idle socket expiry.
