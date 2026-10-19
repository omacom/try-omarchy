import Darwin
import Foundation
import notify
import Testing
@testable import OmarchyVMHelper

@Suite("Mac time zone wire contract")
struct TimeZoneBridgeTests {
    @Test("Only bounded zone identifiers can enter the guest boot command line")
    func identifiers() {
        for zone in ["Asia/Tokyo", "Europe/Lisbon", "America/Argentina/Buenos_Aires", "Etc/GMT+9", "UTC"] {
            #expect(HostTimeZone.isValid(zone))
        }
        for zone in ["", "../UTC", "/UTC", "Asia//Tokyo", "Asia/./Tokyo", "Asia/../Tokyo", "UTC/",
                     "UTC systemd.unit=rescue.target", "UTC\n", String(repeating: "A", count: 129)] {
            #expect(!HostTimeZone.isValid(zone))
        }
    }

    @Test("Host messages contain only a zone name, never a clock correction")
    func message() throws {
        let data = try HostTimeZone.message("Asia/Tokyo")
        #expect(data.last == 10)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object == ["type": "timezone", "zone": "Asia/Tokyo"])
        #expect(throws: (any Error).self) { try HostTimeZone.message("../UTC") }
    }

    @Test("A wake prompt carries no time; the guest reads its own RTC")
    func wakeMessage() throws {
        #expect(HostWake.message.last == 10)
        let object = try #require(JSONSerialization.jsonObject(with: HostWake.message) as? [String: String])
        #expect(object == ["type": "wake"])
    }

    @Test("Each wake post makes the bridge's descriptor readable once")
    func wakeObservation() throws {
        let name = "dev.tryomarchy.test.host-wake.\(UUID().uuidString)"
        let observation = try #require(HostWakeObservation(name: name))
        #expect(!observation.drain())
        notify_post(name)
        notify_post(name)
        var event = pollfd(fd: observation.descriptor, events: Int16(POLLIN), revents: 0)
        #expect(poll(&event, 1, 2000) == 1)
        #expect(observation.drain())
        #expect(!observation.drain())
    }

    @Test("Capture reads the system zone on this Mac")
    func capture() {
        #expect(HostTimeZone.current() == NSTimeZone.system.identifier)
        #expect(HostTimeZone.isValid(HostTimeZone.current()))
    }
}
