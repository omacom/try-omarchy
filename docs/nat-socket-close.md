# NAT socket-close stalls

On a Mac with a content filter, such as a web-protection or security app with a network extension, closing a TCP socket can take a long time. macOS can make `close()` wait for the filter even on a nonblocking socket ([content_filter.c](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/content_filter.c)). libslirp closes NAT sockets on QEMU's main loop, so one slow close froze the keyboard, the display and every other device until it returned.

The runtime's libslirp closes TCP sockets on a GLib thread pool instead. When a connection ends, the main thread stops polling its socket and queues the descriptor, and a pool thread closes it. The pool adds a thread only while every running one is busy, up to 16, and idle threads exit. If all 16 are blocked, later closes wait in the queue and connections keep working. Once 1,024 closes are waiting, further closes happen on the main loop again, so a filter that never lets go can't use up QEMU's descriptors. Shutting down the network doesn't wait for queued closes.

This covers every TCP connection libslirp closes, outgoing or forwarded. Listening sockets for forwarded ports still close on the main loop, so their ports are free as soon as the network shuts down. UDP and ICMP sockets also still close there. It doesn't make a filter's close any faster.

The runtime pins [libslirp 4.9.7](https://gitlab.freedesktop.org/slirp/libslirp/-/tags/v4.9.7) and checks its source and patch hashes.

## Checks

`make runtime` runs libslirp's test suite, including `tcp-close`. It checks that IPv4 and IPv6 connections close on the pool with their payload and EOF intact, that a stalled close holds up neither later closes nor cleanup, that a failed bind keeps its error, that a forwarded port is free when cleanup returns, and that the queue stops growing when every close is stalled. `make test` checks the patch's pinned checksum.
