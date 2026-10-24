import Foundation
import Testing
@testable import OmarchyVMHelper

struct FIDOSimulatedGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    mutating func report() -> [UInt8] {
        (0..<64).map { _ in UInt8(truncatingIfNeeded: next() >> 32) }
    }
}

final class FIDOSimulatedDevice: FIDOReportDevice {
    var reports: [[UInt8]] = []
    var closes = 0
    var onWrite: (([UInt8]) -> Void)?

    func write(_ report: [UInt8]) throws { reports.append(report); onWrite?(report) }
    func close() { closes += 1 }
}

enum FIDOSimulatedFixtures {
    static let seed: UInt64 = 0xf1d0_2026_1021
    static let descriptorSizes: [UInt32] = [1, 2, 4, 8, 16, 32]

    static func item(_ type: UInt8, _ tag: UInt8, _ value: UInt32, width: Int = 1) -> [UInt8] {
        let minimum = value > 0xffff ? 4 : value > 0xff ? 2 : 1
        let size = max(width, minimum)
        let code: UInt8 = size == 4 ? 3 : UInt8(size)
        return [(tag << 4) | (type << 2) | code]
            + (0..<size).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    static func descriptor(inputSize: UInt32 = 8, outputSize: UInt32 = 8,
                           width: Int = 1, savedGlobals: Bool = false,
                           nesting: Int = 0, reportID: UInt32? = nil) -> Data {
        var bytes = item(1, 0, 0xf1d0, width: width) + item(2, 0, 1, width: width) + [0xa1, 1]
        if savedGlobals {
            bytes += [0xa4] + item(1, 0, 7) + item(1, 7, 3) + item(1, 9, 2) + [0xb4]
        }
        for _ in 0..<nesting { bytes += item(2, 0, 0x20) + [0xa1, 0] }
        if let reportID { bytes += item(1, 8, reportID) }
        bytes += item(1, 1, 0) + item(1, 2, 1)
        bytes += item(2, 0, 0x20, width: width) + item(1, 7, inputSize, width: width)
            + item(1, 9, 512 / inputSize, width: width) + [0x81, 2]
        bytes += item(2, 0, 0x21, width: width) + item(1, 7, outputSize, width: width)
            + item(1, 9, 512 / outputSize, width: width) + [0x91, 2]
        bytes += [UInt8](repeating: 0xc0, count: nesting + 1)
        return Data(bytes)
    }

    static func supports(_ descriptor: Data, transport: String = "USB",
                         page: Int = 0xf1d0, usage: Int = 1,
                         input: Int = 64, output: Int = 64) -> Bool {
        FIDODevicePolicy.supports(transport: transport, usagePage: page, usage: usage,
                                 inputBytes: input, outputBytes: output, descriptor: descriptor)
    }

    static func report(channel: UInt32, command: UInt8 = 0x90, size: Int = 1) -> [UInt8] {
        [UInt8(channel >> 24), UInt8(truncatingIfNeeded: channel >> 16),
         UInt8(truncatingIfNeeded: channel >> 8), UInt8(truncatingIfNeeded: channel),
         command, UInt8(size >> 8), UInt8(size & 255)] + [UInt8](repeating: 0, count: 57)
    }
}

@Suite("Simulated FIDO device contracts")
struct FIDOSimulatedDeviceTests {
    @Test("the supported report contract survives field widths, saved globals and physical collections")
    func generatedDescriptorShapes() {
        var cases = 0
        for input in FIDOSimulatedFixtures.descriptorSizes {
            for output in FIDOSimulatedFixtures.descriptorSizes {
                for width in [1, 2, 4] {
                    for saved in [false, true] {
                        for nesting in [0, 1, 7] {
                            let descriptor = FIDOSimulatedFixtures.descriptor(
                                inputSize: input, outputSize: output, width: width,
                                savedGlobals: saved, nesting: nesting)
                            #expect(FIDOSimulatedFixtures.supports(descriptor))
                            cases += 1
                        }
                    }
                }
            }
        }
        #expect(cases == 648)
        print("FIDO_SIM_CASES descriptor_supported_shapes=\(cases)")
    }

    @Test("valid descriptors cannot qualify through unrelated device properties")
    func propertyMismatches() {
        var cases = 0
        for size in FIDOSimulatedFixtures.descriptorSizes {
            let descriptor = FIDOSimulatedFixtures.descriptor(inputSize: size)
            for transport in ["", "usb", "Bluetooth", "Bluetooth Low Energy", "NFC", "I2C"] {
                #expect(!FIDOSimulatedFixtures.supports(descriptor, transport: transport))
                cases += 1
            }
            for page in [0, 1, 7, 0xff00, 0xf1cf, 0xf1d1] {
                #expect(!FIDOSimulatedFixtures.supports(descriptor, page: page))
                cases += 1
            }
            for usage in [0, 2, 6, 0x20, 0x21] {
                #expect(!FIDOSimulatedFixtures.supports(descriptor, usage: usage))
                cases += 1
            }
            for bytes in [-1, 0, 1, 32, 63, 65, 128, 4096] {
                #expect(!FIDOSimulatedFixtures.supports(descriptor, input: bytes))
                #expect(!FIDOSimulatedFixtures.supports(descriptor, output: bytes))
                cases += 2
            }
        }
        #expect(cases == 198)
        print("FIDO_SIM_CASES discovery_property_mismatches=\(cases)")
    }

    @Test("unsupported layouts and malformed descriptors never become selected devices")
    func rejectedDescriptorShapes() {
        let good = FIDOSimulatedFixtures.descriptor()
        var bad: [Data] = (0..<good.count).map { Data(good.prefix($0)) }
        bad += [0, 1, 255].map { FIDOSimulatedFixtures.descriptor(reportID: UInt32($0)) }
        bad += [good + good, good + Data([0xfe]), Data([0xb4]) + good]
        bad += [FIDOSimulatedFixtures.descriptor(nesting: 8)]
        for field: UInt8 in [0x75, 0x95] {
            for value: UInt8 in [0, 33, 63, 65, 255] {
                var changed = Array(good)
                if let offset = changed.firstIndex(of: field) { changed[offset + 1] = value }
                bad.append(Data(changed))
            }
        }
        for usage: UInt8 in [0, 1, 0x21, 0xff] {
            var changed = Array(good)
            let marker = [UInt8](arrayLiteral: 0x09, 0x20)
            let offset = changed.indices.first { $0 + 1 < changed.count && Array(changed[$0...($0 + 1)]) == marker }!
            changed[offset + 1] = usage
            bad.append(Data(changed))
        }
        let keyboard = Data([0x05, 1, 0x09, 6, 0xa1, 1, 0x75, 8, 0x95, 1, 0x81, 2, 0xc0])
        bad += [keyboard + good, good + keyboard]
        bad.append(good.dropLast() + Data([0x05, 1, 0x09, 6, 0x75, 8, 0x95, 1, 0x81, 2, 0xc0]))
        var extendedUsage = Array(good)
        extendedUsage.replaceSubrange(3..<5, with: [0x0b, 1, 0, 0xd0, 0xf1])
        bad.append(Data(extendedUsage))
        for (index, descriptor) in bad.enumerated() {
            let supported = FIDOSimulatedFixtures.supports(descriptor)
            #expect(!supported)
            let identity = FIDODeviceIdentity(registryID: UInt64(index + 1), name: "Synthetic", isSupported: supported)
            #expect(FIDODevicePolicy.selected(registryID: identity.registryID, from: [identity]) == nil)
        }
        var atLimit = Array(good.dropLast())
        while atLimit.count + 3 <= 4096 { atLimit += [0x15, 0] }
        atLimit += [0xc0]
        #expect(atLimit.count == 4096)
        #expect(FIDOSimulatedFixtures.supports(Data(atLimit)))
        let overLimit = Array(atLimit.dropLast()) + [0x15, 0, 0xc0]
        #expect(!FIDOSimulatedFixtures.supports(Data(overLimit)))
        print("FIDO_SIM_CASES descriptor_rejected_shapes=\(bad.count + 1) descriptor_limit_positive=1")
    }

    @Test("names, order and synthetic device churn cannot replace the exact registry entry")
    func generatedSelectionPools() throws {
        var generator = FIDOSimulatedGenerator(seed: FIDOSimulatedFixtures.seed)
        var cases = 0
        for index in 0..<128 {
            let id = generator.next() | 1
            let replacementID = id ^ 0x8000_0000_0000_0000
            let name = ["USB FIDO key", "", "Synthetic vendor \u{1f511}", "same model"][index % 4]
            let chosen = FIDODeviceIdentity(registryID: id, name: name, isSupported: true)
            let twin = FIDODeviceIdentity(registryID: replacementID, name: name, isSupported: true)
            let unsupported = FIDODeviceIdentity(registryID: id, name: name, isSupported: false)
            let pools: [([FIDODeviceIdentity], FIDODeviceIdentity?)] = [
                ([chosen, twin], chosen), ([twin, chosen], chosen), ([twin], nil), ([], nil),
                ([unsupported, twin], nil), ([chosen, chosen], nil), ([chosen, unsupported], nil),
            ]
            for (pool, expected) in pools {
                #expect(FIDODevicePolicy.selected(registryID: id, from: pool) == expected)
                var opens = 0
                let device = FIDOSimulatedDevice()
                let session = FIDOForwardingSession {
                    guard FIDODevicePolicy.selected(registryID: id, from: pool) != nil else {
                        throw NSError(domain: "synthetic-selection", code: 1)
                    }
                    opens += 1
                    return device
                }
                if expected == nil {
                    #expect(throws: (any Error).self) { try session.receive(.hello(Array(0..<16))) }
                    #expect(opens == 0)
                } else {
                    #expect(try session.receive(.hello(Array(0..<16))) == .ready(Array(0..<16)))
                    #expect(opens == 1)
                }
                session.close()
                session.close()
                #expect(device.closes == (expected == nil ? 0 : 1))
                cases += 1
            }
            #expect(FIDODevicePolicy.registryID(chosen.selector) == id)
        }
        #expect(cases == 896)
        for id: UInt64 in [1, 0xff, 0xffff, 0xffff_ffff, UInt64.max] {
            let identity = FIDODeviceIdentity(registryID: id, name: "", isSupported: true)
            #expect(FIDODevicePolicy.registryID(identity.selector) == id)
        }
        print("FIDO_SIM_CASES selection_pools=\(cases) selector_roundtrips=133")
    }

    @Test("unrelated replies cannot forget pending work, while complete replies do")
    func pendingResponses() throws {
        var generator = FIDOSimulatedGenerator(seed: FIDOSimulatedFixtures.seed)
        var cases = 0
        for command: UInt8 in [0x90, 0x83, 0x81] {
            for size in [0, 1, 57, 58, 116, 117, 408, 7609] {
                let channel = UInt32(truncatingIfNeeded: generator.next()) | 1
                let request = FIDOSimulatedFixtures.report(channel: channel, command: command)
                for complete in (size > 57 ? [false, true] : [true]) {
                    let device = FIDOSimulatedDevice()
                    let session = FIDOForwardingSession { device }
                    _ = try session.receive(.hello(Array(0..<16)))
                    _ = try session.receive(.report(request))
                    _ = try session.receivedReport(FIDOSimulatedFixtures.report(
                        channel: channel ^ 0x8000_0000, command: 0xbf))
                    _ = try session.receivedReport(FIDOSimulatedFixtures.report(channel: channel, command: 0xbb))
                    _ = try session.receivedReport(FIDOSimulatedFixtures.report(channel: channel, command: 0x82))
                    _ = try session.receivedReport(FIDOSimulatedFixtures.report(channel: channel, command: 0))
                    _ = try session.receivedReport(FIDOSimulatedFixtures.report(
                        channel: channel, command: command, size: size))
                    let continuations = max(0, (size - 57 + 58) / 59)
                    if continuations > 0 {
                        _ = try session.receivedReport(FIDOSimulatedFixtures.report(channel: channel, command: 1))
                        let delivered = complete ? continuations : continuations - 1
                        for sequence in 0..<delivered {
                            _ = try session.receivedReport(FIDOSimulatedFixtures.report(
                                channel: channel, command: UInt8(sequence)))
                        }
                    }
                    session.close()
                    session.close()
                    let expected: [UInt8] = complete ? [command]
                        : command == 0x90 ? [command, 0x91, 0x86] : [command, 0x86]
                    #expect(device.reports.map { $0[4] } == expected)
                    #expect(device.closes == 1)
                    #expect(throws: (any Error).self) { try session.receivedReport(request) }
                    cases += 1
                }
            }
        }
        #expect(cases == 39)
        print("FIDO_SIM_CASES pending_response_sessions=\(cases)")
    }
}
