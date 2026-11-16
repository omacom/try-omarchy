# NAT socket-close stalls

On Darwin, outgoing NAT TCP sockets close on background workers so a slow host close does not block QEMU's main loop. The change is local to the Mac runtime. It does not change Omarchy, the network route, or host network protections.

## Why this is needed

A libslirp 4.9.7 control spent all 1,202 main-thread samples in `net_slirp_receive → tcp_input → tcp_close → close` during a failed-connection workload. Earlier browser tests reproduced the visible freeze and repeated typed letters. During a package download with the earlier worker implementation, workers handled delayed closes while the main thread kept running.

Darwin's [content-filter socket-close path](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/content_filter.c) can wait even when a socket is nonblocking. Moving the close prevents this wait from blocking virtual-device service. It does not make the host close complete faster.

## Ownership and limits

Each outgoing TCP connection allocates a cleanup record before creating a host socket. If allocation fails, the connection attempt returns `ENOMEM` before opening a socket. Existing connections remain unchanged. Socket creation failure frees the record and preserves the socket error.

When a connection ends, the main thread removes it from polling and transfers its descriptor and record to a close worker. This transfer makes no allocation. Failed binds and failed connections use the same close path as completed connections. Workers own only the record, descriptor, and pool. They do not access freed Slirp or protocol state. A close is attempted once because retrying after `EINTR` could close a reused descriptor. The worker then frees the record.

Each Slirp instance starts 16 workers. Normally, one worker closes sockets. When queued closes stop making progress, the pool puts more of its existing workers to work. It returns to one active closer when the queue and in-flight work are both empty. This reduces wakeups when closes finish quickly, but starting additional closers takes time.

There is no fixed connection count or cleanup-record inventory. Records use 24 bytes each on arm64 before allocator overhead. The operating system's memory and file-descriptor limits still apply. A prolonged close backlog can exhaust those resources. If all 16 workers are blocked, new connections can still open and exchange data, but further close completion waits for a worker to return.

Worker notifications use the public macOS address-wait API. Notifications remain visible to a worker that has not entered its wait yet. An interrupted wait checks the queue again. Other wait errors switch that pool to ordinary condition variables for the rest of its life. Worker priority remains unchanged.

Pool shutdown returns without waiting for blocked closes and lets all workers drain the queue. The last worker frees the pool. A host close that never returns retains its worker and pool. The worker count limits simultaneous close calls, not healthy connections.

If workers cannot start, libslirp fails initialization. The companion QEMU change reports that error and cleans up without dereferencing a null Slirp instance. There is no synchronous fallback for admitted outgoing TCP connections.

Incoming forwarded TCP, UDP, ICMP, auxiliary descriptors, and other host waits retain their existing close paths. This patch does not guarantee that every possible network stall leaves the VM responsive.

## Source and compatibility

The runtime pins [libslirp 4.9.7](https://gitlab.com/qemu-project/libslirp/-/tree/ce12dcddf710a71dc0de6450ec95edbadf8e9f66) and checks its source and patch hashes. The ICMP and UDP patches are rebased onto that version while retaining its packet-validation and security fixes. The guest remains stock Omarchy.

## Checks

`make test` runs the portable worker regression and the host's adaptive-worker and notification checks. `make runtime` applies the pinned patches and runs the full libslirp Meson suite, including TCP integration and ICMP/UDP checks. `make app`, `make kit`, and `make test-kit` check the built artifacts. `make e2e` exercises the real VM from first boot through shutdown and a second boot.

The worker checks cover 32,768 blocked closes, further reservations while workers are blocked, allocation failure, cancellation, partial initialization failure, and asynchronous cleanup. The TCP integration check covers IPv4 and IPv6, failed socket creation and binds, poll removal before close, and preservation of payload and EOF.

Additional checks cover initialization failure, interrupted closes and descriptor reuse, concurrent reserve/cancel/submit operations, blocked workers, notification failures, shutdown and repeated pool lifetimes. The current source passed native sanitizer and static checks, 12 Linux programs in normal and sanitizer builds, and a 20,000-live-connection test with IPv4 and IPv6. These checks do not establish performance on every Mac.

## Validation status

The current design passed `make doctor`, `make test`, `make runtime`, `make app`, and `make kit`, including the kit checker. The full `make e2e` run passed all 107 checks. Local builds used ad hoc signing. macOS 15 compiler checks passed; runtime checks on the supported macOS CI versions remain pending.

A 20-pair native comparison used the exact built libraries, the same idle period before each version, and complete worker cleanup. All data and resource checks passed. Completion time increased 2.77%, with a one-sided 95% upper bound of 4.05%. CPU time increased 4.42%, with an upper bound of 6.21%. The candidate did not meet the declared performance limits.

An eight-boot VM comparison used the original and patched runtimes with Malwarebytes filtering disabled. All 248,192 requests completed, including 8,192 warmup requests. All connection, cooldown, health and cleanup checks passed. Malwarebytes filtering was restored and verified afterward. Final checks also confirmed that Proton VPN was connected and the firewall was enabled.

The four paired VM comparisons measured 0.54% more completion time, with a one-sided 95% upper bound of 2.16%. The p95 latency criterion passed; the p99 criterion did not. The completion criteria also did not pass. These results cover this Mac and this local HTTP workload. Four pairs leave uncertainty, and the recorded VM CPU does not establish complete worker cleanup cost.

The same tested build was then installed for a user test with Malwarebytes filtering enabled. The user logged into the existing VM and reported normal operation. The running process was verified to use the tested library.

Profiles identify worker wait and wake operations as a recurring cost for serial closes. Requests already in the queue share most notification costs. These results support the freeze fix on the tested Mac and record its measured cost; they do not establish a speed improvement for unaffected users.
