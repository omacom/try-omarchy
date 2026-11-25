import Darwin
import Foundation
import IOKit.pwr_mgt

/// The guest's Stay Awake state, one `on` or `off` line at a time. Other lines are ignored.
struct StayAwakeRequestBuffer {
    private var lines = GuestLineBuffer(maximumLineBytes: 64)

    /// The last complete state in `data`, or nil when it holds none.
    mutating func consume(_ data: some Sequence<UInt8>) -> Bool? {
        var state: Bool?
        for line in lines.consume(data) {
            if line == Data("on".utf8) { state = true }
            if line == Data("off".utf8) { state = false }
        }
        return state
    }
}

/// Whether the guest still wants the Mac awake. QEMU keeps the socket open
/// when the guest restarts or its reporter stops, so an `on` that is not
/// resent has to expire. The reporter (stay-awake-report) resends every 10 s.
struct StayAwakeState {
    static let expiry: Duration = .seconds(30)
    private var expires: ContinuousClock.Instant?

    mutating func report(_ awake: Bool, at now: ContinuousClock.Instant) {
        expires = awake ? now + Self.expiry : nil
    }

    func isAwake(at now: ContinuousClock.Instant) -> Bool {
        expires.map { now < $0 } ?? false
    }
}

/// Keeps the Mac's display and system awake while the guest asks it to.
final class StayAwakeAssertion {
    private let create: () -> IOPMAssertionID?
    private let release: (IOPMAssertionID) -> Void
    private var identifier: IOPMAssertionID?

    init(
        create: @escaping () -> IOPMAssertionID? = createDisplaySleepAssertion,
        release: @escaping (IOPMAssertionID) -> Void = { IOPMAssertionRelease($0) }
    ) {
        self.create = create
        self.release = release
    }

    func set(_ awake: Bool) {
        if awake {
            if identifier == nil { identifier = create() }
        } else if let held = identifier {
            release(held)
            identifier = nil
        }
    }

    static func createDisplaySleepAssertion() -> IOPMAssertionID? {
        var created = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Omarchy Stay Awake" as CFString,
            &created
        )
        return result == kIOReturnSuccess ? created : nil
    }
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
        try serve(descriptor: descriptor, assertion: StayAwakeAssertion()) { identity.isStillRunning }
    }

    static func serve(
        descriptor: Int32,
        assertion: StayAwakeAssertion,
        now: () -> ContinuousClock.Instant = { ContinuousClock.now },
        whileRunning isRunning: () -> Bool
    ) throws {
        defer { assertion.set(false) }
        var requests = StayAwakeRequestBuffer()
        var state = StayAwakeState()
        var bytes = [UInt8](repeating: 0, count: 512)
        while isRunning() {
            assertion.set(state.isAwake(at: now()))
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
            if let awake = requests.consume(bytes.prefix(count)) {
                state.report(awake, at: now())
            }
        }
    }
}
