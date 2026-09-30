import Foundation
import Testing

@testable import OmarchyVMHelper

@Suite struct HostBatterySnapshotTests {
    private func description(
        percent: Int = 57,
        max: Int = 100,
        state: String = "Battery Power",
        charging: Bool = false,
        charged: Bool = false,
        toEmptyMinutes: Int = 135,
        toFullMinutes: Int = -1
    ) -> [String: Any] {
        [
            "Type": "InternalBattery",
            "Is Present": true,
            "Current Capacity": percent,
            "Max Capacity": max,
            "Power Source State": state,
            "Is Charging": charging,
            "Is Charged": charged,
            "Time to Empty": toEmptyMinutes,
            "Time to Full Charge": toFullMinutes,
        ]
    }

    @Test func dischargingSnapshotEncodesTheWireContract() throws {
        let snapshot = HostBatterySnapshot(descriptions: [description()])
        #expect(snapshot.present)
        #expect(snapshot.percentage == 57)
        #expect(snapshot.state == "discharging")
        #expect(!snapshot.acConnected)
        #expect(snapshot.timeToEmptySeconds == 135 * 60)
        #expect(snapshot.timeToFullSeconds == nil)
        let line = String(data: snapshot.encode(), encoding: .utf8)!
        #expect(line.hasSuffix("\n"))
        let object = try JSONSerialization.jsonObject(
            with: snapshot.encode()) as! [String: Any]
        #expect(object["type"] as? String == "state")
        #expect(object["percentage"] as? Int == 57)
        #expect(object["timeToFullSeconds"] is NSNull)
        // Pin the wire contract's key set exactly; the guest agent parses
        // by these keys, and neither extras nor omissions are safe to add
        // silently.
        #expect(
            Set(object.keys) == [
                "acConnected", "percentage", "present", "state",
                "timeToEmptySeconds", "timeToFullSeconds", "type",
            ]
        )
    }

    @Test func chargingAndChargedMapToTheProtocolTokens() {
        let charging = HostBatterySnapshot(descriptions: [
            description(state: "AC Power", charging: true, toEmptyMinutes: -1, toFullMinutes: 45)
        ])
        #expect(charging.state == "charging")
        #expect(charging.acConnected)
        #expect(charging.timeToFullSeconds == 45 * 60)
        let full = HostBatterySnapshot(descriptions: [
            description(percent: 100, state: "AC Power", charged: true, toEmptyMinutes: -1)
        ])
        #expect(full.state == "full")
        let idle = HostBatterySnapshot(descriptions: [
            description(state: "AC Power", toEmptyMinutes: -1)
        ])
        #expect(idle.state == "not-charging")
    }

    @Test func desktopMacReportsNoBatteryOnMains() {
        let snapshot = HostBatterySnapshot(descriptions: [])
        #expect(!snapshot.present)
        #expect(snapshot.percentage == nil)
        #expect(snapshot.acConnected)
        #expect(snapshot.state == "unknown")
    }

    @Test func absentInternalBatteryIsSkipped() {
        // The predicate accepts a missing "Is Present" key but must reject an
        // explicit false, or a removed battery would be mirrored as present.
        var absent = description()
        absent["Is Present"] = false
        let snapshot = HostBatterySnapshot(descriptions: [absent])
        #expect(!snapshot.present)
        #expect(snapshot.percentage == nil)
        #expect(snapshot.state == "unknown")
        #expect(snapshot.acConnected)
    }

    @Test func percentageIsScaledByMaxCapacity() {
        let snapshot = HostBatterySnapshot(descriptions: [
            description(percent: 40, max: 80)
        ])
        #expect(snapshot.percentage == 50)
    }

    @Test func chargeLimitIsOptionalAndIndependentOfCurrentCharge() throws {
        let snapshot = HostBatterySnapshot(descriptions: [description(percent: 42)], chargeLimit: 95)
        #expect(snapshot.percentage == 42)
        #expect(snapshot.chargeLimit == 95)
        let legacy = try JSONSerialization.jsonObject(with: snapshot.encode()) as! [String: Any]
        #expect(legacy["chargeLimit"] == nil)
        let extended = try JSONSerialization.jsonObject(with: snapshot.encode(includeChargeLimit: true)) as! [String: Any]
        #expect(extended["chargeLimit"] as? Int == 95)
        for limit in [0, 100, 101] {
            #expect(HostBatterySnapshot(descriptions: [description()], chargeLimit: limit).chargeLimit == nil)
        }
        #expect(HostBatterySnapshot(descriptions: [], chargeLimit: 95).chargeLimit == nil)
    }

    @Test func changingOnlyTheChargeLimitSendsANewSnapshot() {
        var policy = BatterySendPolicy()
        policy.markSent(HostBatterySnapshot(descriptions: [description()], chargeLimit: 80))
        #expect(policy.shouldSend(HostBatterySnapshot(descriptions: [description()], chargeLimit: 95), forced: false))
    }

    @Test func physicalDetailsAreNegotiatedIndependentlyAndAbsentBatteryClearsThem() throws {
        let details = HostBatteryDetails(properties: ["CycleCount": 213])
        let snapshot = HostBatterySnapshot(descriptions: [description()], chargeLimit: 95, details: details)
        let limitOnly = try JSONSerialization.jsonObject(with: snapshot.encode(includeChargeLimit: true)) as! [String: Any]
        #expect(limitOnly["cycleCount"] == nil)
        let extended = try JSONSerialization.jsonObject(with: snapshot.encode(includeChargeLimit: true, includeBatteryDetails: true)) as! [String: Any]
        #expect(extended["cycleCount"] as? Int == 213)
        #expect(extended["chargeFullMicroAh"] is NSNull)
        let absent = HostBatterySnapshot(descriptions: [], details: details)
        #expect(absent.details.cycleCount == nil)
        var policy = BatterySendPolicy()
        policy.markSent(snapshot)
        #expect(policy.shouldSend(HostBatterySnapshot(descriptions: [description()], chargeLimit: 95,
            details: HostBatteryDetails(properties: ["CycleCount": 214])), forced: false))
    }
}

@Suite struct HostBatteryDetailsTests {
    @Test func nestedAppleSiliconReadingsUsePhysicalUnits() {
        let details = HostBatteryDetails(properties: [
            "CurrentCapacity": 95, "MaxCapacity": 100, "Voltage": 12537, "CycleCount": 213,
            "BatteryData": ["RemainingCapacity": 4652, "FullChargeCapacity": 4970, "DesignCapacity": 6075],
        ])
        #expect(details.chargeNowMicroAh == 4_652_000)
        #expect(details.chargeFullMicroAh == 4_970_000)
        #expect(details.chargeFullDesignMicroAh == 6_075_000)
        #expect(details.voltageMicroV == 12_537_000)
        #expect(details.cycleCount == 213)
    }

    @Test func olderRawReadingsAndZeroCyclesAreSupported() {
        let details = HostBatteryDetails(properties: [
            "AppleRawCurrentCapacity": 0, "AppleRawMaxCapacity": 4970,
            "DesignCapacity": 6075, "CycleCount": 0,
        ])
        #expect(details.chargeNowMicroAh == 0)
        #expect(details.chargeFullMicroAh == 4_970_000)
        #expect(details.chargeFullDesignMicroAh == 6_075_000)
        #expect(details.cycleCount == 0)
        #expect(details.voltageMicroV == nil)
    }

    @Test func normalizedAndMalformedReadingsNeverBecomePhysicalCapacity() {
        let normalized = HostBatteryDetails(properties: ["CurrentCapacity": 95, "MaxCapacity": 100])
        #expect(normalized.chargeNowMicroAh == nil)
        #expect(normalized.chargeFullMicroAh == nil)
        for value in [true, -1, 0, Int.max, 1.5, "4970"] as [Any] {
            let details = HostBatteryDetails(properties: ["AppleRawMaxCapacity": value, "Voltage": value])
            #expect(details.chargeFullMicroAh == nil)
            #expect(details.voltageMicroV == nil)
        }
        #expect(HostBatteryDetails(properties: ["CycleCount": true]).cycleCount == nil)
    }
}

@objc(TryOmarchyTestChargingPolicy)
final class TestChargingPolicy: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let reason: String
    let limit: Int
    let terminated: Bool

    init(_ reason: String, limit: Int, terminated: Bool = false) {
        self.reason = reason
        self.limit = limit
        self.terminated = terminated
    }
    required init?(coder: NSCoder) { fatalError("Encoding fixture only") }
    func encode(with coder: NSCoder) {
        coder.encode(reason as NSString, forKey: "reason")
        coder.encode(limit, forKey: "soclimit")
        coder.encode(terminated, forKey: "terminated")
    }
}

@Suite struct HostChargeLimitTests {
    private func plist(_ policies: [TestChargingPolicy]) throws -> Data {
        let encoder = NSKeyedArchiver(requiringSecureCoding: true)
        encoder.setClassName("ChargeCtrlPolicy", for: TestChargingPolicy.self)
        encoder.encode(policies as NSArray, forKey: NSKeyedArchiveRootObjectKey)
        encoder.finishEncoding()
        return try PropertyListSerialization.data(fromPropertyList: ["policies": encoder.encodedData], format: .binary, options: 0)
    }

    @Test func onlyActiveManualPoliciesSupplyALimit() throws {
        #expect(HostChargeLimit.read(try plist([
            TestChargingPolicy("optimizedCharging", limit: 80),
            TestChargingPolicy("manualChargeLimit", limit: 85, terminated: true),
            TestChargingPolicy("manualChargeLimit", limit: 95),
        ])) == 95)
    }

    @Test func missingDisabledAndMalformedPoliciesHaveNoLimit() throws {
        #expect(HostChargeLimit.read(Data("invalid".utf8)) == nil)
        #expect(HostChargeLimit.read(try plist([])) == nil)
        for limit in [-1, 0, 100, 101] {
            #expect(HostChargeLimit.read(try plist([TestChargingPolicy("manualChargeLimit", limit: limit)])) == nil)
        }
    }
}

@Suite struct BatterySendPolicyTests {
    @Test func duplicateSnapshotsAreCoalescedUntilForced() {
        var policy = BatterySendPolicy()
        let snapshot = HostBatterySnapshot(descriptions: [])
        #expect(policy.shouldSend(snapshot, forced: false))
        policy.markSent(snapshot)
        #expect(!policy.shouldSend(snapshot, forced: false))
        #expect(policy.shouldSend(snapshot, forced: true))
    }

    @Test func changedSnapshotAlwaysSends() {
        var policy = BatterySendPolicy()
        let mains = HostBatterySnapshot(descriptions: [])
        policy.markSent(mains)
        let battery = HostBatterySnapshot(descriptions: [[
            "Type": "InternalBattery",
            "Is Present": true,
            "Current Capacity": 12,
            "Max Capacity": 100,
            "Power Source State": "Battery Power",
            "Is Charging": false,
            "Is Charged": false,
            "Time to Empty": -1,
            "Time to Full Charge": -1,
        ]])
        #expect(policy.shouldSend(battery, forced: false))
    }
}

@Suite struct BatteryGuestRequestTests {
    @Test func refreshLineIsRecognizedAndOthersAreIgnored() {
        #expect(NativeBatteryBridge.isRefreshRequest(Data(#"{"type":"refresh"}"#.utf8)))
        #expect(!NativeBatteryBridge.isRefreshRequest(Data(#"{"type":"state"}"#.utf8)))
        #expect(!NativeBatteryBridge.isRefreshRequest(Data("garbage".utf8)))
    }
}

@Suite struct GuestLineReaderTests {
    @Test func decodesLinesSplitAcrossFeedCalls() {
        var reader = GuestLineReader()
        let first = Array(#"{"type":"ref"#.utf8)
        let second = Array("resh\"}\n".utf8)
        #expect(reader.feed(first[...]).isEmpty)
        let lines = reader.feed(second[...])
        #expect(lines.count == 1)
        #expect(NativeBatteryBridge.isRefreshRequest(lines[0]))
    }

    @Test func decodesMultipleLinesInOneFeedCall() {
        var reader = GuestLineReader()
        let chunk = Array(#"{"type":"refresh"}"# + "\n" + #"{"type":"refresh"}"# + "\n")
            .map { UInt8($0.asciiValue!) }
        let lines = reader.feed(chunk[...])
        #expect(lines.count == 2)
        #expect(lines.allSatisfy(NativeBatteryBridge.isRefreshRequest))
    }

    /// Guards Finding 2: an oversized guest line must never be treated as
    /// fatal — the wire contract requires every non-refresh guest byte to
    /// be ignored, not to terminate the bridge. This drops the overflow
    /// silently and keeps parsing the next line normally.
    @Test func anOversizedLineIsDroppedAndParsingResumesAfterItsNewline() {
        var reader = GuestLineReader()
        let overflow = [UInt8](repeating: UInt8(ascii: "x"), count: GuestLineReader.maximumLineBytes + 1)
        #expect(reader.feed(overflow[...]).isEmpty)
        // The overflow line's own terminating newline, immediately followed
        // by a well-formed refresh request: the guest keeps talking right
        // after sending garbage, and that refresh must still be honored.
        let rest = Array(("\n" + #"{"type":"refresh"}"# + "\n").utf8)
        let lines = reader.feed(rest[...])
        #expect(lines.count == 1)
        #expect(NativeBatteryBridge.isRefreshRequest(lines[0]))
    }

    @Test func anOversizedLineSpanningMultipleFeedCallsIsStillDropped() {
        var reader = GuestLineReader()
        let half = [UInt8](repeating: UInt8(ascii: "x"), count: GuestLineReader.maximumLineBytes)
        #expect(reader.feed(half[...]).isEmpty)
        #expect(reader.feed(half[...]).isEmpty) // now well past the limit, still no newline
        let rest = Array(("\n" + #"{"type":"refresh"}"# + "\n").utf8)
        let lines = reader.feed(rest[...])
        #expect(lines.count == 1)
        #expect(NativeBatteryBridge.isRefreshRequest(lines[0]))
    }
}
