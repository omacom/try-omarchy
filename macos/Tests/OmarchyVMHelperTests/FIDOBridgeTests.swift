import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("FIDO forwarding")
struct FIDOBridgeTests {
    private let descriptor = Data([
        0x06, 0xd0, 0xf1, 0x09, 0x01, 0xa1, 0x01, 0x09, 0x20, 0x15, 0x00,
        0x26, 0xff, 0x00, 0x75, 0x08, 0x95, 0x40, 0x81, 0x02, 0x09, 0x21,
        0x15, 0x00, 0x26, 0xff, 0x00, 0x75, 0x08, 0x95, 0x40, 0x91, 0x02, 0xc0,
    ])

    private final class Device: FIDOReportDevice {
        var reports: [[UInt8]] = []
        var closes = 0
        var failWrites = false

        func write(_ report: [UInt8]) throws {
            if failWrites { throw NSError(domain: "synthetic-device", code: 1) }
            reports.append(report)
        }

        func close() { closes += 1 }
    }

    private func report(cid: UInt32 = 0x01020304, command: UInt8 = 0x90,
                        size: Int = 1) -> [UInt8] {
        [UInt8(cid >> 24), UInt8(truncatingIfNeeded: cid >> 16), UInt8(truncatingIfNeeded: cid >> 8),
         UInt8(truncatingIfNeeded: cid), command, UInt8(size >> 8), UInt8(size & 255)]
            + [UInt8](repeating: 0, count: 57)
    }

    @Test("FIDO discovery is by USB usage and descriptor, without a vendor filter")
    func descriptorDiscovery() {
        #expect(FIDODevicePolicy.supports(transport: "USB", usagePage: 0xf1d0, usage: 1,
                                          inputBytes: 64, outputBytes: 64, descriptor: descriptor))
        for (transport, page, usage, input, output) in [
            ("Bluetooth", 0xf1d0, 1, 64, 64), ("USB", 1, 1, 64, 64),
            ("USB", 0xf1d0, 6, 64, 64), ("USB", 0xf1d0, 1, 65, 64),
            ("USB", 0xf1d0, 1, 64, 32),
        ] {
            #expect(!FIDODevicePolicy.supports(transport: transport, usagePage: page, usage: usage,
                                               inputBytes: input, outputBytes: output, descriptor: descriptor))
        }
    }

    @Test("unsupported descriptors cannot acquire an interface")
    func rejectsOtherHIDLayouts() {
        var numbered = descriptor
        numbered.insert(contentsOf: [0x85, 1], at: 7)
        var keyboard = descriptor
        keyboard.replaceSubrange(0..<5, with: [0x05, 1, 0x09, 6])
        var short = descriptor
        short[17] = 32
        for value in [Data(), numbered, keyboard, short, descriptor.dropLast(),
                      descriptor + descriptor, descriptor + Data([0xfe]), Data(repeating: 0, count: 4097)] {
            #expect(!FIDODevicePolicy.supportsDescriptor(value))
        }
    }

    @Test("selection cannot substitute a twin or use an ambiguous identifier")
    func exactSelection() {
        let chosen = FIDODeviceIdentity(registryID: 42, name: "One", isSupported: true)
        let twin = FIDODeviceIdentity(registryID: 43, name: "One", isSupported: true)
        #expect(FIDODevicePolicy.selected(registryID: 42, from: [chosen, twin]) == chosen)
        #expect(FIDODevicePolicy.selected(registryID: 42, from: [twin]) == nil)
        #expect(FIDODevicePolicy.selected(registryID: 42, from: [chosen, chosen]) == nil)
        #expect(FIDODevicePolicy.selected(registryID: 42, from: [
            FIDODeviceIdentity(registryID: 42, name: "One", isSupported: false),
        ]) == nil)
        #expect(FIDODevicePolicy.registryID(chosen.selector) == 42)
        for selector in ["", "42", "0x0", "0x", "0x10000000000000000", "0x2a --anything", "0xＧ"] {
            #expect(FIDODevicePolicy.registryID(selector) == nil)
        }
    }

    @Test("wire framing survives every split and matches the guest's version-one greeting")
    func fragmentedFrames() throws {
        let frames: [FIDOFrame] = [.hello, .ready, .report(report()), .ping, .pong, .bye]
        #expect(FIDOFrame.hello.bytes == [0x54, 0x4f, 0x46, 0x44, 1, 1, 0, 0])
        let bytes = frames.flatMap(\.bytes)
        for split in 0...bytes.count {
            var reader = FIDOFrameReader()
            let first = try reader.feed(Array(bytes[..<split]))
            let second = try reader.feed(Array(bytes[split...]))
            #expect(first + second == frames)
            try reader.finish()
        }
    }

    @Test("invalid headers are rejected before their advertised payload is buffered")
    func malformedFrames() {
        for header: [UInt8] in [
            [0, 0x4f, 0x46, 0x44, 1, 1, 0, 0], [0x54, 0x4f, 0x46, 0x44, 2, 1, 0, 0],
            [0x54, 0x4f, 0x46, 0x44, 1, 7, 0, 0], [0x54, 0x4f, 0x46, 0x44, 1, 3, 255, 255],
            [0x54, 0x4f, 0x46, 0x44, 1, 3, 0, 63], [0x54, 0x4f, 0x46, 0x44, 1, 1, 0, 1],
        ] {
            var reader = FIDOFrameReader()
            #expect(throws: (any Error).self) { try reader.feed(header) }
        }
        var truncated = FIDOFrameReader()
        _ = try? truncated.feed([0x54])
        #expect(throws: (any Error).self) { try truncated.finish() }
    }

    @Test("an undrained guest cannot grow the host queue without bound")
    func backpressure() throws {
        var output = FIDOOutputBuffer()
        let frame = FIDOFrame.report(report())
        for _ in 0..<(FIDOOutputBuffer.limit / frame.bytes.count) { try output.append(frame) }
        #expect(throws: (any Error).self) { try output.append(frame) }
        output.consume(frame.bytes.count)
        try output.append(.ping)
        #expect(output.bytes.suffix(8) == FIDOFrame.ping.bytes[...])
    }

    @Test("only the matching hello opens the selected device, once")
    func handshakeOwnsTheDevice() throws {
        let device = Device()
        var opens = 0
        let session = FIDOForwardingSession { opens += 1; return device }
        #expect(opens == 0)
        #expect(try session.receive(.hello) == .ready)
        #expect(opens == 1)
        #expect(try session.receive(.ping) == .pong)
        _ = try session.receive(.report(report()))
        #expect(device.reports == [report()])
        #expect(throws: (any Error).self) { try session.receive(.hello) }
        #expect(device.closes == 1)
        #expect(opens == 1)
        session.close()
        #expect(device.closes == 1)
    }

    @Test("an incompatible or absent guest does not touch a physical key")
    func noAcquireBeforeNegotiation() {
        for frame in [FIDOFrame.ready, .ping, .report(report()), .bye] {
            var opens = 0
            let session = FIDOForwardingSession { opens += 1; return Device() }
            #expect(throws: (any Error).self) { try session.receive(frame) }
            #expect(opens == 0)
        }
    }

    @Test("shutdown cancels pending CBOR and resynchronizes before closing")
    func releaseCancelsPendingWork() throws {
        let device = Device()
        let session = FIDOForwardingSession { device }
        _ = try session.receive(.hello)
        _ = try session.receive(.report(report()))
        _ = try session.receivedReport(report(command: 0xbb))
        _ = try session.receive(.bye)
        #expect(device.closes == 1)
        #expect(device.reports.map { $0[4] } == [0x90, 0x91, 0x86])
        #expect(device.reports.allSatisfy { Array($0.prefix(4)) == [1, 2, 3, 4] })
        #expect(device.reports.last?[6] == 8)
    }

    @Test("complete multiframe responses are not cancelled after release")
    func completedRequestsAreForgotten() throws {
        let device = Device()
        let session = FIDOForwardingSession { device }
        _ = try session.receive(.hello)
        _ = try session.receive(.report(report()))
        _ = try session.receivedReport(report(size: 408))
        for index in 0..<6 {
            var continuation = report()
            continuation[4] = UInt8(index)
            _ = try session.receivedReport(continuation)
        }
        session.close()
        #expect(device.reports.count == 1)
        #expect(device.closes == 1)
    }

    @Test("write failures still release the interface exactly once")
    func failureReleasesTheKey() throws {
        let device = Device()
        let session = FIDOForwardingSession { device }
        _ = try session.receive(.hello)
        device.failWrites = true
        #expect(throws: (any Error).self) { try session.receive(.report(report())) }
        #expect(session.isClosed)
        #expect(device.closes == 1)
    }

    @Test("storage reset strips the key selection")
    func resetDoesNotAcquireAKey() {
        #expect(QEMUGPURuntimeEnvironment.sanitizedForReset([
            FIDODevicePolicy.environmentKey: "0x2a",
        ])[FIDODevicePolicy.environmentKey] == nil)
    }
}
