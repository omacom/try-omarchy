import Darwin
import Foundation
import notify

enum HostTimeZone {
    static func isValid(_ identifier: String) -> Bool {
        !identifier.isEmpty && identifier.utf8.count <= 128
            && !identifier.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                $0.isEmpty || $0 == "." || $0 == ".."
            })
            && identifier.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0)
                    || (48...57).contains($0) || [47, 95, 45, 43].contains($0)
            }
    }

    static func current() -> String {
        NSTimeZone.resetSystemTimeZone()
        return TimeZone.current.identifier
    }

    static func message(_ identifier: String) throws -> Data {
        guard isValid(identifier) else { throw HelperError.io("unsupported Mac time zone") }
        var data = try JSONSerialization.data(withJSONObject: ["type": "timezone", "zone": identifier])
        data.append(10)
        return data
    }
}

/// The helper posts this once the Mac wakes. A paused guest's clock falls
/// behind, so the time zone bridge asks the guest to check it against its
/// RTC. The message carries no time; any local process may post it, and the
/// guest only re-reads its own hardware clock.
enum HostWake {
    static let notification = "dev.tryomarchy.host-wake"
    static let message = Data(#"{"type":"wake"}"#.utf8) + [10]

    static func post() { notify_post(notification) }
}

/// A descriptor that turns readable each time `HostWake` is posted.
final class HostWakeObservation {
    let descriptor: Int32
    private let token: Int32

    init?(name: String = HostWake.notification) {
        var descriptor: Int32 = -1
        var token: Int32 = 0
        guard notify_register_file_descriptor(name, &descriptor, 0, &token) == NOTIFY_STATUS_OK else {
            return nil
        }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        self.descriptor = descriptor
        self.token = token
    }

    deinit { notify_cancel(token) }

    /// Consume every pending post; true when there was at least one.
    func drain() -> Bool {
        var token: Int32 = 0
        var posted = false
        while Darwin.read(descriptor, &token, MemoryLayout<Int32>.size) == MemoryLayout<Int32>.size {
            posted = true
        }
        return posted
    }
}

/// This channel publishes only a zone name and wake prompts. Guest input
/// cannot change the Mac.
final class NativeTimeZoneBridge {
    private let descriptor: Int32

    init(targetPID: pid_t, socketPath: String) throws {
        guard let identity = KernelProcessIdentity.capture(processIdentifier: targetPID),
              identity.isQEMUSystemProcess else {
            throw HelperError.io("time zone bridge target is not a QEMU system process")
        }
        descriptor = try NativeBridgeSocket.connectSecure(path: socketPath, label: "time zone")
    }

    deinit { Darwin.close(descriptor) }

    func run() throws {
        // Without it the guest still finds a lost clock within its timer interval.
        let wake = HostWakeObservation()
        var input = [UInt8](repeating: 0, count: 512)
        while true {
            try NativeBridgeSocket.writeAll(HostTimeZone.message(HostTimeZone.current()),
                                           to: descriptor, label: "time zone")
            // Refresh at most every five seconds, and right after wake. Drain
            // guest input without interpreting it or letting it trigger sends.
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            waiting: while ProcessInfo.processInfo.systemUptime < deadline {
                var events = [pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0),
                              pollfd(fd: wake?.descriptor ?? -1, events: Int16(POLLIN), revents: 0)]
                let remaining = Int32(max(1, (deadline - ProcessInfo.processInfo.systemUptime) * 1000))
                let result = Darwin.poll(&events, 2, remaining)
                if result < 0 && errno == EINTR { continue }
                if result < 0 { throw HelperError.io("cannot poll time zone channel") }
                if result == 0 { break }
                if events[1].revents != 0, wake?.drain() == true {
                    // Written while QEMU may still be stopped; the guest reads
                    // it as soon as the VM continues. The zone follows, in
                    // case the Mac changed it while asleep.
                    try NativeBridgeSocket.writeAll(HostWake.message, to: descriptor, label: "time zone")
                    break waiting
                }
                guard events[0].revents != 0 else { continue }
                let count = Darwin.read(descriptor, &input, input.count)
                if count == 0 { return }
                if count < 0 && errno != EINTR { throw HelperError.io("cannot read time zone channel") }
            }
        }
    }
}
