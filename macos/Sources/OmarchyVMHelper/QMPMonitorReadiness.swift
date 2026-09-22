import Darwin
import Foundation

/// Socket files appear during QEMU initialization, before its main loop can
/// answer QMP. Only a completed handshake is a usable readiness signal.
enum QMPMonitorReadiness {
    static func wait(targetPID: pid_t, socketPath: String) throws {
        guard let identity = KernelProcessIdentity.capture(processIdentifier: targetPID) else {
            throw HelperError.io("QEMU exited before its QMP monitor became ready")
        }
        try wait(isTargetAlive: { identity.isStillRunning }) { timeout in
            try QMPConnection(
                socketPath: socketPath,
                identifierPrefix: "omarchy-readiness",
                timeoutMilliseconds: timeout,
                expectedPeerPID: targetPID
            )
        }
    }

    static func wait(
        timeoutMilliseconds: Int32 = 60_000,
        nowNanoseconds: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        isTargetAlive: () -> Bool,
        connect: (Int32) throws -> QMPConnection
    ) throws {
        let deadline = nowNanoseconds()
            + UInt64(max(0, timeoutMilliseconds)) * 1_000_000
        var lastError: Error?
        while true {
            guard isTargetAlive() else {
                throw HelperError.io("QEMU exited before its QMP monitor became ready")
            }
            let now = nowNanoseconds()
            guard now < deadline, (deadline - now) / 1_000_000 > 0 else { break }
            let attemptTimeout = Int32(min(250, (deadline - now) / 1_000_000))
            do {
                let connection = try connect(attemptTimeout)
                connection.close()
                return
            } catch {
                lastError = error
            }
            // A timed-out connection can occupy QEMU's backlog during init.
            // Its main loop drains it once running; retry on a fresh socket.
            guard isTargetAlive() else {
                throw HelperError.io("QEMU exited before its QMP monitor became ready")
            }
            let afterAttempt = nowNanoseconds()
            guard afterAttempt < deadline else { break }
            sleep(min(0.1, Double(deadline - afterAttempt) / 1_000_000_000))
        }
        let detail = lastError.map { ": \($0.localizedDescription)" } ?? ""
        throw HelperError.io("QMP monitor readiness timed out\(detail)")
    }
}
