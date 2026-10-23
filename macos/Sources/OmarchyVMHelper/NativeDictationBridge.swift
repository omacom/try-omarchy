import Darwin
import Foundation

/// The recogniser behind the dictation bridge. Implementations keep their own
/// serial queue; the bridge calls them in the order the guest's commands
/// arrive and never twice for one command.
protocol DictationEngine: AnyObject, Sendable {
    var availability: DictationAvailability { get }
    /// The guest (re)opened the port: warm up what can be warmed up.
    func prepare()
    func start(session: Int, model: DictationModel, events: @escaping @Sendable (DictationEvent) -> Void)
    func stop(session: Int)
    func cancel(session: Int)
}

/// Host half of dev.tryomarchy.dictation (docs/host-dictation.md). One port
/// carries every session, so the bridge tags events with the guest's session
/// ids and keeps at most one session live.
final class NativeDictationBridge: @unchecked Sendable {
    static let maximumLineBytes = 64 * 1024
    /// Ended sessions remembered so their late events are dropped.
    private static let endedSessionWindow = 64

    private let descriptor: Int32
    private let engine: DictationEngine
    private let lock = NSLock()
    private var live: Int?
    private var ended = Set<Int>()
    private var newestSession = 0
    private var stopped = false

    /// A guest that stops reading (its service stopped mid-session, so QEMU
    /// stops draining the port) fails a write after this long, and the live
    /// session ends instead of recording for nobody.
    static let writeTimeoutSeconds = 2.0

    init(targetPID: pid_t, socketPath: String, engine: DictationEngine) throws {
        guard let processIdentity = KernelProcessIdentity.capture(processIdentifier: targetPID),
              processIdentity.isQEMUSystemProcess else {
            throw HelperError.io("native dictation bridge target is not a QEMU system process")
        }
        descriptor = try NativeBridgeSocket.connectSecure(path: socketPath, label: "dictation bridge")
        self.engine = engine
        Self.setWriteTimeout(descriptor, seconds: Self.writeTimeoutSeconds)
    }

    /// Test-only: an already-connected stream, such as one end of a socketpair.
    init(descriptor: Int32, engine: DictationEngine, writeTimeoutSeconds: Double = NativeDictationBridge.writeTimeoutSeconds) {
        var enabled: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        self.descriptor = descriptor
        self.engine = engine
        Self.setWriteTimeout(descriptor, seconds: writeTimeoutSeconds)
    }

    private static func setWriteTimeout(_ descriptor: Int32, seconds: Double) {
        var timeout = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit {
        stop()
    }

    /// Returns when QEMU closes the channel.
    func run() throws {
        var reader = GuestLineReader(maximumLineBytes: Self.maximumLineBytes)
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                for line in reader.feed(chunk[0..<count]) {
                    if let command = DictationGuestCommand.decode(line) {
                        handle(command)
                    }
                }
            } else if count == 0 || isStopped {
                return
            } else if errno != EINTR {
                throw HelperError.io("cannot read the guest dictation channel")
            }
        }
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    // Engine calls happen outside the lock, so an engine that reports an
    // event synchronously cannot deadlock the bridge; the read loop is the
    // only caller, which keeps them in arrival order.
    private func handle(_ command: DictationGuestCommand) {
        switch command {
        case .hello:
            let availability = engine.availability
            lock.lock()
            let restarted = live
            live = nil
            writeLocked(DictationHostMessage.hello(availability))
            lock.unlock()
            if let restarted { engine.cancel(session: restarted) }
            engine.prepare()

        case let .start(session, model):
            if case let .unavailable(reason) = engine.availability {
                lock.lock()
                remember(session)
                ended.insert(session)
                writeLocked(DictationHostMessage.event(.error(reason), session: session))
                lock.unlock()
                return
            }
            lock.lock()
            let replaced = live
            live = session
            remember(session)
            ended.remove(session)
            lock.unlock()
            if let replaced, replaced != session { engine.cancel(session: replaced) }
            engine.start(session: session, model: model) { [weak self] event in
                self?.deliver(event, session: session)
            }

        case let .stop(session):
            if isLive(session) { engine.stop(session: session) }

        case let .cancel(session):
            if isLive(session) { engine.cancel(session: session) }

        case let .ping(id):
            lock.lock()
            writeLocked(DictationHostMessage.pong(id: id, liveSession: live))
            lock.unlock()
        }
    }

    private func isLive(_ session: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return live == session
    }

    private func deliver(_ event: DictationEvent, session: Int) {
        lock.lock()
        guard !ended.contains(session) else {
            lock.unlock()
            return
        }
        if event.isTerminal {
            ended.insert(session)
            if live == session { live = nil }
        }
        let delivered = writeLocked(DictationHostMessage.event(event, session: session))
        let stalled = !delivered && !stopped && live == session
        if stalled {
            ended.insert(session)
            live = nil
        }
        lock.unlock()
        if stalled {
            fputs("[dictation-bridge] the guest stopped reading; ending session \(session)\n", stderr)
            engine.cancel(session: session)
        }
    }

    /// Caller holds `lock`.
    private func remember(_ session: Int) {
        newestSession = max(newestSession, session)
        ended = ended.filter { $0 > newestSession - Self.endedSessionWindow }
    }

    /// Caller holds `lock`. A failed write means QEMU is going away (the read
    /// loop sees the same and ends the bridge) or the guest stopped reading.
    @discardableResult
    private func writeLocked(_ data: Data) -> Bool {
        guard !stopped else { return false }
        do {
            try NativeBridgeSocket.writeAll(data, to: descriptor, label: "dictation bridge")
            return true
        } catch {
            fputs("[dictation-bridge] \(error)\n", stderr)
            return false
        }
    }
}
