import Darwin
import Foundation
import IOKit.ps
import notify

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
    let chargeLimit: Int?
    let details: HostBatteryDetails

    init(descriptions: [[String: Any]], chargeLimit: Int? = nil, details: HostBatteryDetails = HostBatteryDetails()) {
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
            self.chargeLimit = nil
            self.details = HostBatteryDetails()
            return
        }
        present = true
        self.details = details
        self.chargeLimit = chargeLimit.flatMap { (1..<100).contains($0) ? $0 : nil }
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

    func encode(includeChargeLimit: Bool = false, includeBatteryDetails: Bool = false,
                includeBatteryCurrent: Bool = false) -> Data {
        var object: [String: Any] = [
            "type": "state",
            "present": present,
            "percentage": percentage as Any? ?? NSNull(),
            "state": state,
            "acConnected": acConnected,
            "timeToEmptySeconds": timeToEmptySeconds as Any? ?? NSNull(),
            "timeToFullSeconds": timeToFullSeconds as Any? ?? NSNull(),
        ]
        // Older guest agents reject extra keys. Advertise only after opt-in.
        if includeChargeLimit { object["chargeLimit"] = chargeLimit as Any? ?? NSNull() }
        if includeBatteryDetails {
            object["chargeNowMicroAh"] = details.chargeNowMicroAh as Any? ?? NSNull()
            object["chargeFullMicroAh"] = details.chargeFullMicroAh as Any? ?? NSNull()
            object["chargeFullDesignMicroAh"] = details.chargeFullDesignMicroAh as Any? ?? NSNull()
            object["voltageMicroV"] = details.voltageMicroV as Any? ?? NSNull()
            object["cycleCount"] = details.cycleCount as Any? ?? NSNull()
        }
        if includeBatteryCurrent { object["currentMicroA"] = details.currentMicroA as Any? ?? NSNull() }
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
        return HostBatterySnapshot(descriptions: descriptions, chargeLimit: HostChargeLimit.capture(), details: HostBatteryDetails.capture())
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

/// Observe every published power-source attribute, including charging-only
/// changes while percentage and time estimates stay unchanged. The IOPS run
/// loop convenience API observes only time/percentage/source notifications.
/// Dispatch delivery also works while the bridge's main thread reads its port.
final class BatteryPowerObservation {
    private let token: Int32

    init?(queue: DispatchQueue, name: String = kIOPSNotifyAnyPowerSource,
          onChange: @escaping @Sendable () -> Void) {
        var token: Int32 = 0
        guard notify_register_dispatch(name, &token, queue, { _ in onChange() }) == NOTIFY_STATUS_OK else {
            return nil
        }
        self.token = token
    }

    deinit { notify_cancel(token) }
}

final class NativeBatteryBridge: @unchecked Sendable {
    static let heartbeatSeconds = 30.0

    private let descriptor: Int32
    private let stateQueue = DispatchQueue(label: "dev.tryomarchy.native.battery-bridge-state")
    private let stopLock = NSLock()
    private var policy = BatterySendPolicy()
    private var supportsChargeLimit = false
    private var supportsBatteryDetails = false
    private var supportsBatteryCurrent = false
    private var heartbeat: DispatchSourceTimer?
    private var powerObservation: BatteryPowerObservation?
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
                        let request = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                        sendSync(forced: true, includeChargeLimit: request?["chargeLimit"] as? Bool == true,
                                 includeBatteryDetails: request?["batteryDetails"] as? Bool == true,
                                 includeBatteryCurrent: request?["batteryCurrent"] as? Bool == true)
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
        powerObservation = nil
        let timer = heartbeat
        heartbeat = nil
        stopLock.unlock()
        timer?.cancel()
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    private func hasStopped() -> Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopped
    }

    private func startPowerNotifications() {
        stopLock.lock()
        defer { stopLock.unlock() }
        guard !stopped else { return }
        powerObservation = BatteryPowerObservation(queue: stateQueue) { [weak self] in
            self?.sendOnQueue(forced: false)
        }
        if powerObservation == nil {
            fputs("[battery-bridge] IOKit power notifications are unavailable; relying on the heartbeat\n", stderr)
        }
    }

    private func startHeartbeat() {
        stopLock.lock()
        defer { stopLock.unlock() }
        guard !stopped else { return }
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

    /// Queues the initial snapshot without blocking the port reader.
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
    private func sendSync(forced: Bool, includeChargeLimit: Bool, includeBatteryDetails: Bool,
                          includeBatteryCurrent: Bool) {
        stateQueue.sync {
            // Each refresh also resets negotiation when an older agent reconnects.
            supportsChargeLimit = includeChargeLimit
            supportsBatteryDetails = includeBatteryDetails
            supportsBatteryCurrent = includeBatteryCurrent
            sendOnQueue(forced: forced)
        }
    }

    /// The actual send. Must only run on `stateQueue`.
    private func sendOnQueue(forced: Bool) {
        guard !hasStopped() else { return }
        let snapshot = HostBatterySnapshot.capture()
        guard policy.shouldSend(snapshot, forced: forced) else { return }
        do {
            try NativeBridgeSocket.writeAll(snapshot.encode(includeChargeLimit: supportsChargeLimit,
                                                           includeBatteryDetails: supportsBatteryDetails,
                                                           includeBatteryCurrent: supportsBatteryCurrent),
                                            to: descriptor, label: "battery")
            policy.markSent(snapshot)
        } catch {
            fputs("[battery-bridge] \(error.localizedDescription)\n", stderr)
            stop()
        }
    }
}
