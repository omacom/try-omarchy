import Darwin
import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Native FIDO channel", .serialized)
@MainActor
struct NativeFIDOBridgeTests {
    private final class Device: FIDOReportDevice {
        var closes = 0
        func write(_ report: [UInt8]) throws {}
        func close() { closes += 1 }
    }

    private func pair() throws -> [Int32] {
        var descriptors: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        return descriptors
    }

    @Test("a guest that never negotiates cannot acquire the key")
    func missingPeerDoesNotAcquire() throws {
        let sockets = try pair()
        defer { Darwin.close(sockets[0]) }
        var opens = 0
        var instant = ContinuousClock.now
        let bridge = try NativeFIDOBridge(descriptor: sockets[1], processAlive: { true }, now: {
            defer { instant = instant.advanced(by: .seconds(31)) }
            return instant
        }, openDevice: { _, _ in opens += 1; return Device() })
        #expect(throws: (any Error).self) { try bridge.run() }
        #expect(opens == 0)
    }

    @Test("a negotiated guest that stops heartbeating releases its physical lease")
    func expiredLeaseReleases() throws {
        let sockets = try pair()
        defer { Darwin.close(sockets[0]) }
        let hello = FIDOFrame.hello(Array(0..<16)).bytes
        try #require(hello.withUnsafeBytes { Darwin.write(sockets[0], $0.baseAddress, $0.count) } == hello.count)
        let device = Device()
        let base = ContinuousClock.now
        var opened = false
        var ticks = 0
        let bridge = try NativeFIDOBridge(descriptor: sockets[1], processAlive: { true }, now: {
            if opened { ticks += 1 }
            return base.advanced(by: .seconds(ticks * 11))
        }, openDevice: { _, _ in opened = true; return device })
        #expect(throws: (any Error).self) { try bridge.run() }
        #expect(opened)
        #expect(device.closes == 1)
    }

    @Test("stopping the helper before negotiation leaves all keys alone")
    func stopBeforeHello() throws {
        let sockets = try pair()
        defer { Darwin.close(sockets[0]) }
        var opens = 0
        let bridge = try NativeFIDOBridge(descriptor: sockets[1], processAlive: { true }, openDevice: { _, _ in
            opens += 1
            return Device()
        })
        bridge.stop()
        try bridge.run()
        #expect(opens == 0)
    }
}
