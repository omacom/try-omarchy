import Darwin
import Foundation
import Testing

@testable import OmarchyVMHelper

/// Records what the bridge asks of the recogniser and lets a test play the
/// recogniser's events back through the sink it was given.
private final class FakeDictationEngine: DictationEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var sinks: [Int: @Sendable (DictationEvent) -> Void] = [:]
    private var currentAvailability: DictationAvailability

    init(availability: DictationAvailability = .available(models: [.speech, .dictation], locale: "en-US")) {
        currentAvailability = availability
    }

    var availability: DictationAvailability {
        lock.lock()
        defer { lock.unlock() }
        return currentAvailability
    }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func prepare() { record("prepare") }

    func start(session: Int, model: DictationModel, events: @escaping @Sendable (DictationEvent) -> Void) {
        lock.lock()
        sinks[session] = events
        recorded.append("start \(session) \(model.rawValue)")
        lock.unlock()
    }

    func stop(session: Int) { record("stop \(session)") }
    func cancel(session: Int) { record("cancel \(session)") }

    func emit(_ event: DictationEvent, session: Int) {
        lock.lock()
        let sink = sinks[session]
        lock.unlock()
        sink?(event)
    }

    private func record(_ call: String) {
        lock.lock()
        recorded.append(call)
        lock.unlock()
    }
}

/// The bridge on one end of a socketpair, the test as the guest on the other.
private final class DictationHarness {
    let engine: FakeDictationEngine
    let bridge: NativeDictationBridge
    let guest: Int32
    private let finished = DispatchSemaphore(value: 0)
    private var pending = Data()

    init(engine: FakeDictationEngine = FakeDictationEngine(), writeTimeoutSeconds: Double = 2) throws {
        var descriptors: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        self.engine = engine
        guest = descriptors[1]
        bridge = NativeDictationBridge(descriptor: descriptors[0], engine: engine, writeTimeoutSeconds: writeTimeoutSeconds)
        let bridge = bridge
        let finished = finished
        Thread.detachNewThread {
            try? bridge.run()
            finished.signal()
        }
    }

    deinit {
        bridge.stop()
        Darwin.close(guest)
        _ = finished.wait(timeout: .now() + 2)
    }

    func send(_ text: String) {
        let data = Data(text.utf8)
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { Darwin.write(guest, $0.baseAddress! + offset, $0.count - offset) }
            guard written > 0 else { return }
            offset += written
        }
    }

    /// The next host line, or nil after `timeout` seconds without one.
    func line(timeout: Double = 2) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                return line
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var descriptor = pollfd(fd: guest, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, Int32(remaining * 1000)) > 0 else { return nil }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(guest, &chunk, chunk.count)
            guard count > 0 else { return nil }
            pending.append(contentsOf: chunk[0..<count])
        }
    }

    /// Waits, boundedly, until the engine has seen `count` calls.
    func calls(_ count: Int, timeout: Double = 2) -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        while engine.calls.count < count, Date() < deadline {
            usleep(2_000)
        }
        return engine.calls
    }
}

@Suite("Dictation bridge sessions", .serialized)
struct NativeDictationBridgeTests {
    @Test("Hello is answered with the recogniser's availability and prepares it")
    func helloRepliesAndPrepares() throws {
        let harness = try DictationHarness()
        harness.send(#"{"type":"hello","version":1}"# + "\n")
        #expect(harness.line() == #"{"available":true,"locale":"en-US","models":["speech","dictation"],"type":"hello","version":1}"#)
        #expect(harness.calls(1) == ["prepare"])
    }

    @Test("Events carry their session id and stop after a terminal event")
    func eventsCarryTheSessionId() throws {
        let harness = try DictationHarness()
        harness.send(#"{"type":"start","session":7,"model":"speech"}"# + "\n")
        #expect(harness.calls(1) == ["start 7 speech"])
        harness.engine.emit(.recording, session: 7)
        harness.engine.emit(.partial("hi"), session: 7)
        harness.engine.emit(.final(text: "hi", milliseconds: 90), session: 7)
        harness.engine.emit(.partial("late"), session: 7)
        #expect(harness.line() == #"{"session":7,"type":"recording"}"#)
        #expect(harness.line() == #"{"session":7,"text":"hi","type":"partial"}"#)
        #expect(harness.line() == #"{"ms":90,"session":7,"text":"hi","type":"final"}"#)
        #expect(harness.line(timeout: 0.3) == nil)
    }

    @Test("A start while a session is live cancels the old one first")
    func startWhileLiveCancelsTheOldSession() throws {
        let harness = try DictationHarness()
        harness.send(#"{"type":"start","session":1}"# + "\n" + #"{"type":"start","session":2}"# + "\n")
        #expect(harness.calls(3) == ["start 1 speech", "cancel 1", "start 2 speech"])
        harness.engine.emit(.cancelled, session: 1)
        #expect(harness.line() == #"{"session":1,"type":"cancelled"}"#)
    }

    @Test("Stop and cancel for a session that isn't live are ignored")
    func staleStopAndCancelAreIgnored() throws {
        let harness = try DictationHarness()
        harness.send(#"{"type":"start","session":2}"# + "\n" + #"{"type":"stop","session":1}"# + "\n"
            + #"{"type":"cancel","session":9}"# + "\n" + #"{"type":"ping","id":1}"# + "\n")
        #expect(harness.line() == #"{"id":1,"session":2,"type":"pong"}"#)
        #expect(harness.engine.calls == ["start 2 speech"])
    }

    @Test("A stop right behind its start reaches the recogniser in order")
    func stopFollowsStartInOrder() throws {
        let harness = try DictationHarness()
        harness.send(#"{"type":"start","session":4}"# + "\n" + #"{"type":"stop","session":4}"# + "\n")
        #expect(harness.calls(2) == ["start 4 speech", "stop 4"])
    }

    @Test("A new hello cancels the live session: the guest side restarted")
    func helloCancelsTheLiveSession() throws {
        let harness = try DictationHarness()
        harness.send(#"{"type":"start","session":3}"# + "\n" + #"{"type":"hello","version":1}"# + "\n")
        _ = harness.line()
        #expect(harness.calls(3) == ["start 3 speech", "cancel 3", "prepare"])
        harness.send(#"{"type":"ping","id":2}"# + "\n")
        #expect(harness.line() == #"{"id":2,"type":"pong"}"#)
    }

    @Test("Pong names the live session only while there is one")
    func pongReportsTheLiveSession() throws {
        let harness = try DictationHarness()
        harness.send(#"{"type":"ping","id":5}"# + "\n")
        #expect(harness.line() == #"{"id":5,"type":"pong"}"#)
        harness.send(#"{"type":"start","session":6}"# + "\n" + #"{"type":"ping","id":8}"# + "\n")
        #expect(harness.line() == #"{"id":8,"session":6,"type":"pong"}"#)
        harness.engine.emit(.error("microphone: gone"), session: 6)
        #expect(harness.line() == #"{"message":"microphone: gone","session":6,"type":"error"}"#)
        harness.send(#"{"type":"ping","id":9}"# + "\n")
        #expect(harness.line() == #"{"id":9,"type":"pong"}"#)
    }

    @Test("Without a recogniser, start is answered with the reason")
    func unavailableEngineAnswersStartWithError() throws {
        let harness = try DictationHarness(engine: FakeDictationEngine(availability: .unavailable(reason: "requires macOS 26")))
        harness.send(#"{"type":"start","session":1}"# + "\n")
        #expect(harness.line() == #"{"message":"requires macOS 26","session":1,"type":"error"}"#)
        #expect(harness.engine.calls == [])
    }

    @Test("Oversized and invalid lines are dropped without stopping the bridge")
    func ignoresOversizedAndInvalidLines() throws {
        let harness = try DictationHarness()
        harness.send(String(repeating: "a", count: 70_000) + "\n" + "{]\n" + #"{"type":"ping","id":1}"# + "\n")
        #expect(harness.line() == #"{"id":1,"type":"pong"}"#)
        #expect(harness.engine.calls == [])
    }

    @Test("A guest that stops reading ends the live session instead of holding the microphone")
    func stalledGuestCancelsTheLiveSession() throws {
        let harness = try DictationHarness(writeTimeoutSeconds: 0.2)
        harness.send(#"{"type":"start","session":1}"# + "\n")
        #expect(harness.calls(1) == ["start 1 speech"])
        // The guest never reads: the socket buffer fills and a write stalls.
        let words = String(repeating: "a", count: 4000)
        for _ in 0..<200 where !harness.engine.calls.contains("cancel 1") {
            harness.engine.emit(.partial(words), session: 1)
        }
        #expect(harness.engine.calls == ["start 1 speech", "cancel 1"])
    }

    @Test("The line reader honours a configured limit")
    func guestLineReaderHonoursItsLimit() {
        var reader = GuestLineReader(maximumLineBytes: 8)
        let lines = reader.feed(ArraySlice(Array("123456789\nok\n".utf8)))
        #expect(lines == [Data("ok".utf8)])
    }
}
