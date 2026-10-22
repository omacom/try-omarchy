import Darwin
import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Simulated native FIDO lifecycle", .serialized)
@MainActor
struct FIDOSimulatedLifecycleTests {
    private enum Action {
        case bytes([UInt8])
        case eof
        case stop
        case processExit
        case removed
        case inputLength(Int)
        case outputOverflow
        case echo
    }

    private struct Result {
        let opens: Int
        let device: FIDOSimulatedDevice
        let error: Error?
        let wire: [FIDOFrame]
        let ticks: Int
    }

    private func run(initial: [UInt8], action: Action) throws -> Result {
        var pair: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { Darwin.close(pair[0]) }
        if !initial.isEmpty {
            try #require(initial.withUnsafeBytes { Darwin.write(pair[0], $0.baseAddress, $0.count) } == initial.count)
        }
        let device = FIDOSimulatedDevice()
        var opens = 0
        var tick = 0
        var received: (([UInt8]) -> Void)?
        var removed: (() -> Void)?
        weak var runningBridge: NativeFIDOBridge?
        let bridge = try NativeFIDOBridge(descriptor: pair[1], processAlive: {
            tick += 1
            if tick == 2 {
                switch action {
                case .bytes(let bytes):
                    let count = bytes.withUnsafeBytes { Darwin.write(pair[0], $0.baseAddress, $0.count) }
                    #expect(count == bytes.count)
                case .eof: #expect(Darwin.shutdown(pair[0], SHUT_WR) == 0)
                case .stop: runningBridge?.stop()
                case .processExit: return false
                case .removed: removed?()
                case .inputLength(let length): received?([UInt8](repeating: 0, count: length))
                case .outputOverflow:
                    for _ in 0..<228 { received?([UInt8](repeating: 0, count: 64)) }
                case .echo: break
                }
            }
            return tick < 4
        }, openDevice: { input, failed in
            opens += 1
            received = input
            removed = failed
            if case .echo = action { device.onWrite = input }
            return device
        })
        runningBridge = bridge
        var error: Error?
        do { try bridge.run() } catch let failure { error = failure }
        bridge.stop()
        var wire: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(pair[0], &buffer, buffer.count)
            if count <= 0 { break }
            wire += buffer.prefix(count)
        }
        var reader = FIDOFrameReader()
        let frames = try reader.feed(wire)
        try reader.finish()
        return Result(opens: opens, device: device, error: error, wire: frames, ticks: tick)
    }

    @Test("unnegotiated and incompatible peers never call the fake-device opener")
    func noAcquisitionBeforeHello() throws {
        let report = [UInt8](repeating: 0, count: 64)
        let wrongFrames: [FIDOFrame] = [.ready(Array(0..<16)), .pong, .ping, .bye, .report(report)]
        let badHeaders: [[UInt8]] = [
            [0, 0x4f, 0x46, 0x44, 1, 1, 0, 0],
            [0x54, 0x4f, 0x46, 0x44, 2, 1, 0, 0],
            [0x54, 0x4f, 0x46, 0x44, 1, 7, 0, 0],
            [0x54, 0x4f, 0x46, 0x44, 1, 3, 255, 255],
        ]
        for bytes in wrongFrames.map(\.bytes) + badHeaders.map(FIDOFrame.record) {
            let result = try run(initial: bytes, action: .processExit)
            #expect(result.error != nil)
            #expect(result.opens == 0)
            #expect(result.device.closes == 0)
            #expect(result.device.reports.isEmpty)
            #expect(!result.wire.contains(.ready(Array(0..<16))))
        }
        print("FIDO_SIM_CASES native_no_acquisition=9")
    }

    @Test("bad traffic, device failure, output overflow and peer loss close the acquired device once")
    func acquiredFailureMatrix() throws {
        let wrongDirections = [FIDOFrame.hello(Array(0..<16)), .ready(Array(0..<16)), .pong].map { Action.bytes($0.bytes) }
        let badHeaders: [Action] = [
            .bytes(FIDOFrame.record([0, 0x4f, 0x46, 0x44, 1, 1, 0, 0])),
            .bytes(FIDOFrame.record([0x54, 0x4f, 0x46, 0x44, 1, 3, 255, 255])),
        ]
        let badInputs = [0, 1, 63, 65].map(Action.inputLength)
        let failures = wrongDirections + badHeaders + badInputs + [.removed, .outputOverflow]
        for action in failures {
            let result = try run(initial: FIDOFrame.hello(Array(0..<16)).bytes, action: action)
            #expect(result.error != nil)
            #expect(result.opens == 1)
            #expect(result.device.closes == 1)
            #expect(result.device.reports.isEmpty)
            #expect(result.ticks == 2)
        }
        for action: Action in [.eof, .stop, .processExit] {
            let result = try run(initial: FIDOFrame.hello(Array(0..<16)).bytes, action: action)
            #expect(result.error == nil)
            #expect(result.opens == 1)
            #expect(result.device.closes == 1)
            #expect(result.device.reports.isEmpty)
            #expect(result.ticks == 2)
        }
        print("FIDO_SIM_CASES native_acquired_failures=11 native_acquired_stops=3")
    }

    @Test("the same native channel forwards a valid response before clean shutdown")
    func positiveRoundTrip() throws {
        let packet = FIDOSimulatedFixtures.report(channel: 0x0102_0304)
        let result = try run(initial: FIDOFrame.hello(Array(0..<16)).bytes + FIDOFrame.report(packet).bytes, action: .echo)
        #expect(result.error == nil)
        #expect(result.opens == 1)
        #expect(result.device.closes == 1)
        #expect(result.device.reports == [packet])
        #expect(result.wire == [.ready(Array(0..<16)), .report(packet), .bye])
        print("FIDO_SIM_CASES native_positive_roundtrip=1")
    }

    @Test("a guest restart closes the old channel and a new host channel negotiates again")
    func restartRequiresNewHostSession() throws {
        let oldNonce = Array<UInt8>(0..<16)
        let newNonce = Array<UInt8>((0..<16).reversed())
        let packet = FIDOSimulatedFixtures.report(channel: 0x0102_0304)
        let interrupted = try run(initial: FIDOFrame.hello(oldNonce).bytes,
                                  action: .bytes(Array(FIDOFrame.report(packet).bytes.prefix(64))
                                      + FIDOFrame.hello(newNonce).bytes))
        #expect(interrupted.error != nil)
        #expect(interrupted.opens == 1)
        #expect(interrupted.device.closes == 1)
        #expect(interrupted.device.reports.isEmpty)
        let replacement = try run(initial: FIDOFrame.hello(newNonce).bytes + FIDOFrame.report(packet).bytes,
                                  action: .echo)
        #expect(replacement.error == nil)
        #expect(replacement.opens == 1)
        #expect(replacement.device.reports == [packet])
        #expect(replacement.wire == [.ready(newNonce), .report(packet), .bye])
    }
}
