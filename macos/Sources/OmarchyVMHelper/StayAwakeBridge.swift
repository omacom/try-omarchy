import Darwin
import Foundation
import IOKit.pwr_mgt

/// The guest's Stay Awake state, one `on` or `off` line at a time. Other lines are ignored.
struct StayAwakeRequestBuffer {
    static let maximumLineBytes = 64
    private var line = Data()
    private var discarding = false

    /// The last complete state in `data`, or nil when it holds none.
    mutating func consume(_ data: Data) -> Bool? {
        var state: Bool?
        for byte in data {
            if byte == 10 {
                if !discarding {
                    if line == Data("on".utf8) { state = true }
                    if line == Data("off".utf8) { state = false }
                }
                line.removeAll(keepingCapacity: true)
                discarding = false
            } else if !discarding {
                line.append(byte)
                if line.count > Self.maximumLineBytes {
                    line.removeAll(keepingCapacity: true)
                    discarding = true
                }
            }
        }
        return state
    }
}

/// Keeps the Mac's display and system awake while the guest asks it to.
final class StayAwakeAssertion {
    private var identifier: IOPMAssertionID?

    var isHeld: Bool { identifier != nil }

    func set(_ awake: Bool) {
        if awake {
            guard identifier == nil else { return }
            var created = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Omarchy Stay Awake" as CFString,
                &created
            )
            if result == kIOReturnSuccess { identifier = created }
        } else if let held = identifier {
            IOPMAssertionRelease(held)
            identifier = nil
        }
    }

    deinit { set(false) }
}

/// `--bridge-stay-awake PID SOCKET`: holds the assertion while Omarchy's Stay
/// Awake is on, for as long as QEMU runs. macOS also drops it if this process exits.
enum StayAwakeBridge {
    static func run(targetPID: pid_t, socketPath: String) throws {
        guard let identity = KernelProcessIdentity.capture(processIdentifier: targetPID),
              identity.isQEMUSystemProcess else {
            throw HelperError.io("stay awake target is not QEMU")
        }
        let descriptor = try NativeBridgeSocket.connectSecure(path: socketPath, label: "stay awake")
        defer { Darwin.close(descriptor) }
        let assertion = StayAwakeAssertion()
        defer { assertion.set(false) }
        var requests = StayAwakeRequestBuffer()
        var bytes = [UInt8](repeating: 0, count: 512)
        while identity.isStillRunning {
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, 1000)
            if ready < 0 && errno != EINTR { throw HelperError.io("stay awake poll failed") }
            guard ready > 0 else { continue }
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return
            }
            if let awake = requests.consume(Data(bytes.prefix(count))) {
                assertion.set(awake)
            }
        }
    }
}
