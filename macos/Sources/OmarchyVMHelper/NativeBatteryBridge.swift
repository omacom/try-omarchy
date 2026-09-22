import Darwin
import Foundation
import IOKit.ps

/// One complete host power snapshot, the only message the guest receives.
/// Built from IOPSGetPowerSourceDescription dictionaries so the IOKit-free
/// tests can drive every branch.
struct HostBatterySnapshot: Equatable {
    let present: Bool
    let percentage: Int?
    let state: String
    let acConnected: Bool
    let timeToEmptySeconds: Int?
    let timeToFullSeconds: Int?

    init(descriptions: [[String: Any]]) {
        let internalBattery = descriptions.first { description in
            description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
                && description[kIOPSIsPresentKey] as? Bool != false
        }
        guard let battery = internalBattery else {
            present = false
            percentage = nil
            state = "unknown"
            acConnected = true
            timeToEmptySeconds = nil
            timeToFullSeconds = nil
            return
        }
        present = true
        let current = battery[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maximum = battery[kIOPSMaxCapacityKey] as? Int ?? 100
        percentage = maximum > 0 ? min(100, max(0, current * 100 / maximum)) : 0
        let onMains = battery[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        acConnected = onMains
        if battery[kIOPSIsChargingKey] as? Bool == true {
            state = "charging"
        } else if battery[kIOPSIsChargedKey] as? Bool == true {
            state = "full"
        } else if onMains {
            state = "not-charging"
        } else {
            state = "discharging"
        }
        func seconds(_ key: String) -> Int? {
            guard let minutes = battery[key] as? Int, minutes >= 0 else { return nil }
            return minutes * 60
        }
        timeToEmptySeconds = state == "discharging" ? seconds(kIOPSTimeToEmptyKey) : nil
        timeToFullSeconds = state == "charging" ? seconds(kIOPSTimeToFullChargeKey) : nil
    }

    func encode() -> Data {
        let object: [String: Any] = [
            "type": "state",
            "present": present,
            "percentage": percentage as Any? ?? NSNull(),
            "state": state,
            "acConnected": acConnected,
            "timeToEmptySeconds": timeToEmptySeconds as Any? ?? NSNull(),
            "timeToFullSeconds": timeToFullSeconds as Any? ?? NSNull(),
        ]
        var data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    static func capture() -> HostBatterySnapshot {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return HostBatterySnapshot(descriptions: [])
        }
        let descriptions = list.compactMap {
            IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any]
        }
        return HostBatterySnapshot(descriptions: descriptions)
    }
}

/// Dedupe by value so an IOKit notification burst cannot spam the port; a
/// forced send (guest refresh, 30-second heartbeat) always goes through.
struct BatterySendPolicy {
    private var lastSent: HostBatterySnapshot?

    func shouldSend(_ snapshot: HostBatterySnapshot, forced: Bool) -> Bool {
        forced || snapshot != lastSent
    }

    mutating func markSent(_ snapshot: HostBatterySnapshot) {
        lastSent = snapshot
    }
}

/// Splits a raw guest byte stream into complete newline-delimited lines.
/// A line that exceeds the wire limit is dropped rather than surfaced —
/// every guest byte other than a well-formed refresh is ignored per the
/// wire contract, and an oversized line is guest input like any other; it
/// must not be able to terminate the bridge. Parsing resumes cleanly at the
/// next newline once the oversized line ends.
struct GuestLineReader {
    static let maximumLineBytes = 4096

    private var buffer = Data()
    private var isSkippingOverflow = false

    /// Returns each complete line found in `chunk`, in order. A line that
    /// overflowed while buffering is silently omitted.
    mutating func feed(_ chunk: ArraySlice<UInt8>) -> [Data] {
        var lines: [Data] = []
        var start = chunk.startIndex
        for index in chunk.indices where chunk[index] == 0x0A {
            if !isSkippingOverflow {
                buffer.append(contentsOf: chunk[start..<index])
                lines.append(buffer)
            }
            buffer.removeAll(keepingCapacity: true)
            isSkippingOverflow = false
            start = index + 1
        }
        if !isSkippingOverflow {
            buffer.append(contentsOf: chunk[start..<chunk.endIndex])
            if buffer.count > Self.maximumLineBytes {
                buffer.removeAll(keepingCapacity: true)
                isSkippingOverflow = true
            }
        }
        return lines
    }
}

final class NativeBatteryBridge: @unchecked Sendable {
    static let heartbeatSeconds = 30.0

    private let descriptor: Int32
    private let stateQueue = DispatchQueue(label: "dev.tryomarchy.native.battery-bridge-state")
    private let stopLock = NSLock()
    private var policy = BatterySendPolicy()
    private var heartbeat: DispatchSourceTimer?
    private var powerSource: CFRunLoopSource?
    private var notificationRunLoop: CFRunLoop?
    private var stopped = false

    init(targetPID: pid_t, socketPath: String) throws {
        guard let processIdentity = KernelProcessIdentity.capture(processIdentifier: targetPID),
              processIdentity.isQEMUSystemProcess else {
            throw HelperError.io("native battery bridge target is not a QEMU system process")
        }
        descriptor = try NativeBridgeSocket.connectSecure(path: socketPath, label: "battery bridge")
    }

    deinit {
        stop()
    }

    static func isRefreshRequest(_ line: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return false
        }
        return object["type"] as? String == "refresh"
    }

    func run() throws {
        startPowerNotifications()
        startHeartbeat()
        send(forced: true)
        var reader = GuestLineReader()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                for line in reader.feed(chunk[0..<count]) {
                    // The refresh request is the only guest input; anything
                    // else is ignored so the guest cannot drive this bridge.
                    // Dispatched synchronously so a guest that floods refresh
                    // requests without draining its side is coupled to the
                    // blocking socket write, instead of queuing unbounded
                    // work onto stateQueue.
                    if Self.isRefreshRequest(line) {
                        sendSync(forced: true)
                    }
                }
            } else if count == 0 {
                return
            } else if errno != EINTR {
                throw HelperError.io("cannot read the guest battery channel")
            }
        }
    }

    func stop() {
        stopLock.lock()
        guard !stopped else {
            stopLock.unlock()
            return
        }
        stopped = true
        let source = powerSource
        let loop = notificationRunLoop
        powerSource = nil
        notificationRunLoop = nil
        stopLock.unlock()
        heartbeat?.cancel()
        heartbeat = nil
        if let source, let loop {
            CFRunLoopRemoveSource(loop, source, .defaultMode)
        }
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    private func hasStopped() -> Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopped
    }

    /// Records the run loop source under `stopLock` so `stop()` can tear it
    /// down without racing the detached notification thread that installs
    /// it. Returns false if `stop()` already ran, so the caller can drop the
    /// source it just created instead of leaking it into a torn-down bridge.
    private func registerPowerSource(_ source: CFRunLoopSource, on loop: CFRunLoop) -> Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        guard !stopped else { return false }
        powerSource = source
        notificationRunLoop = loop
        return true
    }

    /// Services IOKit power notifications on a dedicated detached thread's
    /// own run loop, rather than the main run loop. `run()` blocks the
    /// current thread reading the virtio socket, and under `--run-qemu`'s
    /// child-process invocation there is no guarantee anything is pumping
    /// `CFRunLoopGetMain()`; a private run loop on the servicing thread
    /// always exists and is always drained by that same thread's loop.
    private func startPowerNotifications() {
        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            let context = Unmanaged.passUnretained(self).toOpaque()
            guard let source = IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                let bridge = Unmanaged<NativeBatteryBridge>.fromOpaque(context).takeUnretainedValue()
                bridge.send(forced: false)
            }, context)?.takeRetainedValue() else {
                fputs("[battery-bridge] IOKit power notifications are unavailable; relying on the heartbeat\n", stderr)
                return
            }
            let loop = CFRunLoopGetCurrent()!
            guard self.registerPowerSource(source, on: loop) else { return }
            CFRunLoopAddSource(loop, source, .defaultMode)
            while !self.hasStopped() {
                CFRunLoopRunInMode(.defaultMode, 1.0, false)
            }
        }
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(
            deadline: .now() + Self.heartbeatSeconds,
            repeating: Self.heartbeatSeconds,
            leeway: .seconds(1)
        )
        timer.setEventHandler { [weak self] in
            // Already running on stateQueue; call the body directly rather
            // than through `send`/`sendSync` so this can never dispatch
            // onto the queue it is already executing on.
            self?.sendOnQueue(forced: true)
        }
        timer.resume()
        heartbeat = timer
    }

    /// Queues a snapshot send without blocking the caller. Used by the
    /// notification callback and the initial send in `run()`, neither of
    /// which need — or should wait on — completion.
    private func send(forced: Bool) {
        stateQueue.async { [weak self] in
            self?.sendOnQueue(forced: forced)
        }
    }

    /// Queues a snapshot send and blocks the caller until it completes.
    /// The guest's refresh request uses this so a guest that floods refresh
    /// lines without draining its side is throttled by the blocking socket
    /// write instead of piling up unbounded closures on `stateQueue`. Must
    /// never be called from `stateQueue` itself (the heartbeat timer calls
    /// `sendOnQueue` directly for exactly that reason) or this deadlocks.
    private func sendSync(forced: Bool) {
        stateQueue.sync {
            sendOnQueue(forced: forced)
        }
    }

    /// The actual send. Must only run on `stateQueue`.
    private func sendOnQueue(forced: Bool) {
        guard !hasStopped() else { return }
        let snapshot = HostBatterySnapshot.capture()
        guard policy.shouldSend(snapshot, forced: forced) else { return }
        do {
            try NativeBridgeSocket.writeAll(snapshot.encode(), to: descriptor, label: "battery")
            policy.markSent(snapshot)
        } catch {
            fputs("[battery-bridge] \(error.localizedDescription)\n", stderr)
            stop()
        }
    }
}
