import Darwin
import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("QMP monitor readiness")
struct QMPMonitorReadinessTests {
    @Test("refused connections retry within a bounded deadline")
    func refusedMonitor() {
        var now: UInt64 = 1_000_000_000
        var timeouts: [Int32] = []
        var delays: [TimeInterval] = []
        do {
            try QMPMonitorReadiness.wait(
                timeoutMilliseconds: 150,
                nowNanoseconds: { now },
                sleep: { delay in
                    delays.append(delay)
                    now += UInt64((delay * 1_000_000_000).rounded())
                },
                isTargetAlive: { true }
            ) { timeout in
                timeouts.append(timeout)
                now += 20_000_000
                throw HelperError.io("connection refused")
            }
            Issue.record("An unavailable monitor was declared ready")
        } catch {
            #expect(error.localizedDescription.contains("readiness timed out"))
            #expect(error.localizedDescription.contains("connection refused"))
        }
        #expect(timeouts == [150, 30])
        #expect(delays == [0.1, 0.01])
        #expect(now == 1_150_000_000)
    }

    @Test("a scheduler delay past the deadline does not start another probe")
    func delayedWakeup() {
        var now: UInt64 = 0
        var attempts = 0
        do {
            try QMPMonitorReadiness.wait(
                timeoutMilliseconds: 150,
                nowNanoseconds: { now },
                sleep: { _ in now += 1_000_000_000 },
                isTargetAlive: { true }
            ) { _ in
                attempts += 1
                throw HelperError.io("connection refused")
            }
            Issue.record("An unavailable monitor was declared ready")
        } catch {
            #expect(error.localizedDescription.contains("readiness timed out"))
        }
        #expect(attempts == 1)
    }

    @Test("QEMU exit during an attempt stops retries immediately")
    func targetExits() {
        var alive = true
        var attempts = 0
        #expect(throws: HelperError.io("QEMU exited before its QMP monitor became ready")) {
            try QMPMonitorReadiness.wait(isTargetAlive: { alive }) { _ in
                attempts += 1
                alive = false
                throw HelperError.io("socket closed")
            }
        }
        #expect(attempts == 1)
    }

    @Test("a silent greeting or capability reply times out and closes the probe", arguments: [false, true])
    func silentMonitor(sendGreeting: Bool) throws {
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw HelperError.io("Cannot create readiness test socket")
        }
        defer { close(sockets[1]) }
        if sendGreeting {
            try QMPConnection.writeJSON(["QMP": ["capabilities": []]], to: sockets[1])
        }
        // Exercise real socket timeout/cleanup separately from retry timing.
        // The policy tests above use a controlled clock, so runner scheduling
        // cannot consume the budget before this socket has even been tried.
        do {
            let connection = try QMPConnection(
                connectedDescriptor: sockets[0],
                identifierPrefix: "readiness-test",
                timeoutMilliseconds: 150
            )
            connection.close()
            Issue.record("A silent monitor was declared ready")
        } catch {
            #expect(error is HelperError)
        }
        // Drain any capability request and require EOF: failed attempts must
        // release QEMU's single-client monitor for the next connection.
        var bytes = [UInt8](repeating: 0, count: 4096)
        var sawEOF = false
        for _ in 0..<3 {
            var descriptor = pollfd(fd: sockets[1], events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 500) > 0 else { break }
            if read(sockets[1], &bytes, bytes.count) == 0 {
                sawEOF = true
                break
            }
        }
        #expect(sawEOF)
    }
}
