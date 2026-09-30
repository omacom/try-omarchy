import Darwin
import Foundation

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

/// This channel publishes only a zone name. Guest input cannot change the Mac.
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
        var input = [UInt8](repeating: 0, count: 512)
        while true {
            try NativeBridgeSocket.writeAll(HostTimeZone.message(HostTimeZone.current()),
                                           to: descriptor, label: "time zone")
            // Refresh at most every five seconds, including after wake. Drain
            // guest input without interpreting it or letting it trigger sends.
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while ProcessInfo.processInfo.systemUptime < deadline {
                var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let remaining = Int32(max(1, (deadline - ProcessInfo.processInfo.systemUptime) * 1000))
                let result = Darwin.poll(&event, 1, remaining)
                if result < 0 && errno == EINTR { continue }
                if result < 0 { throw HelperError.io("cannot poll time zone channel") }
                if result == 0 { break }
                let count = Darwin.read(descriptor, &input, input.count)
                if count == 0 { return }
                if count < 0 && errno != EINTR { throw HelperError.io("cannot read time zone channel") }
            }
        }
    }
}
