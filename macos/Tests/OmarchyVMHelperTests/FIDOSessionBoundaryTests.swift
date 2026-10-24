import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("FIDO session boundaries")
struct FIDOSessionBoundaryTests {
    private final class Device: FIDOReportDevice {
        var reports: [[UInt8]] = []
        var closes = 0
        func write(_ report: [UInt8]) throws { reports.append(report) }
        func close() { closes += 1 }
    }

    @Test("a restarted guest cannot finish a previous report with its greeting")
    func restartDuringReport() throws {
        let report: [UInt8] = [1, 2, 3, 4, 0x90, 0, 57] + Array(repeating: 0xaa, count: 57)
        let wire = FIDOFrame.report(report).bytes
        for cut in 1..<wire.count {
            let device = Device()
            let session = FIDOForwardingSession { device }
            var reader = FIDOFrameReader()
            for frame in try reader.feed(FIDOFrame.hello(Array(0..<16)).bytes) { _ = try session.receive(frame) }
            do {
                for frame in try reader.feed(Array(wire.prefix(cut))) { _ = try session.receive(frame) }
                for frame in try reader.feed(FIDOFrame.hello(Array(0..<16)).bytes) { _ = try session.receive(frame) }
            } catch {
                session.close()
            }
            #expect(device.reports.isEmpty, "restart after byte \(cut) must not write a mixed report")
            #expect(session.isClosed, "restart must release the previous session at byte \(cut)")
            #expect(device.closes == 1)
        }
    }

    @Test("restart markers cannot be confused with any report payload byte")
    func reservedBytesAreData() throws {
        for offset in stride(from: 0, to: 256, by: 64) {
            let report = (offset..<(offset + 64)).map(UInt8.init)
            let wire = FIDOFrame.report(report).bytes
            for cut in 0...wire.count {
                var reader = FIDOFrameReader()
                let first = try reader.feed(Array(wire.prefix(cut)))
                let second = try reader.feed(Array(wire.dropFirst(cut)))
                #expect(first + second == [.report(report)])
                try reader.finish()
            }
        }
    }

    @Test("a fragmented new greeting aborts every incomplete record, including escapes")
    func restartAtEveryEscapeAndGreetingSplit() throws {
        let report = FIDOFrame.report((0..<64).map { [UInt8(0x7d), 0x7e, 0x7f][$0 % 3] }).bytes
        let greeting = FIDOFrame.hello(Array((0..<16).reversed())).bytes
        for cut in 1..<report.count {
            for split in 0...greeting.count {
                var reader = FIDOFrameReader()
                _ = try reader.feed(Array(report.prefix(cut)))
                let first = try reader.feed(Array(greeting.prefix(split)))
                let second = try reader.feed(Array(greeting.dropFirst(split)))
                #expect(first + second == [.hello(Array((0..<16).reversed()))])
                try reader.finish()
            }
        }
    }

    @Test("old unescaped protocol messages fail before key acquisition")
    func incompatibleProtocolNeverAcquires() throws {
        var reader = FIDOFrameReader()
        var opens = 0
        let session = FIDOForwardingSession { opens += 1; return Device() }
        for frame in try reader.feed([0x54, 0x4f, 0x46, 0x44, 1, 1, 0, 0]) {
            _ = try session.receive(frame)
        }
        #expect(opens == 0)
        #expect(throws: (any Error).self) {
            try reader.feed(FIDOFrame.record([0x54, 0x4f, 0x46, 0x44, 1, 1, 0, 16] + Array(0..<16)))
        }
    }

    @Test("stale bytes before a record do not prevent fresh negotiation")
    func restartAfterUnframedTail() throws {
        let device = Device()
        let session = FIDOForwardingSession { device }
        var reader = FIDOFrameReader()
        let greeting = FIDOFrame.hello(Array(0..<16))
        #expect(try reader.feed([0x44, 0x7f, 0x7d, 0x5e, 0xaa]).isEmpty)
        let frames = try reader.feed(greeting.bytes)
        #expect(frames == [greeting])
        #expect(try session.receive(frames[0]) == .ready(Array(0..<16)))
    }

    @Test("malformed escaped records cannot reach a device")
    func malformedEscapes() {
        for bytes: [UInt8] in [[0x7e, 0x7d, 0], [0x7e, 0x7d, 0x7f], [0x7e, 0x7f],
                               [0x7e, 0x54, 0x4f, 0x46, 0x44, 2, 1, 0, 16] + Array(repeating: 1, count: 17)] {
            var reader = FIDOFrameReader()
            #expect(throws: (any Error).self) { try reader.feed(bytes) }
        }
    }
}
