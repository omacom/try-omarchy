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
