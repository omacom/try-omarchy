import Foundation
import Testing
@testable import OmarchyVMHelper

struct NativeVideoProtocolTests {
    @Test func packetHeaderPreservesOpaqueTokenAndBoundsPayload() throws {
        let message = NativeVideoMessage(operation: .decode, session: 7, token: UInt64.max,
                                         payload: Data([0, 0, 0, 2, 0x26, 1]))
        let encoded = try message.encoded()
        let (decoded, size) = try NativeVideoMessage.parseHeader(Data(encoded.prefix(40)))
        #expect(decoded.operation == .decode)
        #expect(decoded.session == 7)
        #expect(decoded.token == UInt64.max)
        #expect(size == 6)
        #expect(encoded.suffix(6) == message.payload)
    }

    @Test func rejectsFramingChangesAndOversizedAllocationBeforeReadingPayload() throws {
        let good = try NativeVideoMessage(operation: .open, session: 1).encoded()
        for index in [0, 4, 7, 36] {
            var bad = good
            bad[index] = 0xfe
            #expect(throws: (any Error).self) { try NativeVideoMessage.parseHeader(bad) }
        }
        var oversized = good
        oversized[15] = 5 // 80 MiB; must reject before allocating this amount
        #expect(throws: (any Error).self) { try NativeVideoMessage.parseHeader(oversized) }
        for length in 0..<40 {
            #expect(throws: (any Error).self) { try NativeVideoMessage.parseHeader(Data(good.prefix(length))) }
        }
    }

    private func config() -> Data {
        var bytes = Data(repeating: 0, count: 23)
        bytes[0] = 1
        bytes[21] = 3
        bytes[22] = 3
        // Minimal length-valid NAL arrays for the wire parser. These are not
        // valid SPS syntax and deliberately never go into VideoToolbox.
        for type: UInt8 in [32, 33, 34] {
            bytes.append(contentsOf: [type, 0, 1, 0, 2, type << 1, 1])
        }
        return bytes
    }

    @Test func rejectsEveryTruncatedConfigurationAndTrailingData() throws {
        let good = config()
        let parsed = try NativeHEVCConfiguration(good)
        #expect(parsed.parameterSets.count == 3)
        #expect(parsed.nalLengthSize == 4)
        for length in 0..<good.count {
            #expect(throws: (any Error).self) { try NativeHEVCConfiguration(Data(good.prefix(length))) }
        }
        #expect(throws: (any Error).self) { try NativeHEVCConfiguration(good + Data([0])) }
        var wrongType = good
        wrongType[28] = 0
        #expect(throws: (any Error).self) { try NativeHEVCConfiguration(wrongType) }
        var excessiveArrays = good
        excessiveArrays[24] = 1
        #expect(throws: (any Error).self) { try NativeHEVCConfiguration(excessiveArrays) }
    }

    @Test func rejectsNalLengthsThatReachBeyondTheCompressedPacket() throws {
        let parser = try NativeHEVCConfiguration(config())
        try parser.validatePacket(Data([0, 0, 0, 2, 0x26, 1, 0, 0, 0, 3, 0x02, 1, 0xff]))
        for bad: [UInt8] in [[], [0], [0, 0, 0, 0], [0, 0, 0, 1, 0x26],
                             [0, 0, 0, 3, 0x26, 1], [0xff, 0xff, 0xff, 0xff, 0x26, 1]] {
            #expect(throws: (any Error).self) { try parser.validatePacket(Data(bad)) }
        }
    }

    @Test func onlyAdvertisedHEVCBitDepthsAreAccepted() throws {
        for depth: UInt8 in 0...7 {
            var bytes = config()
            bytes[17] = depth
            bytes[18] = depth
            if depth == 0 || depth == 2 {
                #expect(try NativeHEVCConfiguration(bytes).tenBit == (depth == 2))
            } else {
                #expect(throws: (any Error).self) { try NativeHEVCConfiguration(bytes) }
            }
        }
        var mismatch = config()
        mismatch[18] = 2
        #expect(throws: (any Error).self) { try NativeHEVCConfiguration(mismatch) }
    }

    @Test func AV1ProfileAndChromaMustMatchTheAdvertisedSurfaces() throws {
        let eight = Data([0x81, 13, 0x0c, 0])
        let ten = Data([0x81, 13, 0x4c, 0])
        #expect(try !NativeAV1Configuration(eight).tenBit)
        #expect(try NativeAV1Configuration(ten).tenBit)
        for bad in [Data([0x81, 13, 0x0c]), Data([0x80, 13, 0x0c, 0]),
                    Data([0x81, 0x20, 0x0c, 0]), Data([0x81, 13, 0x6c, 0]),
                    Data([0x81, 13, 0x1c, 0]), Data([0x81, 13, 0x40, 0])] {
            #expect(throws: (any Error).self) { try NativeAV1Configuration(bad) }
        }
    }

    @Test func VP9RecordRejectsTruncationAndUnsupportedProfileDepthPairs() throws {
        let eight = Data([1, 0, 0, 0, 0, 51, 0x82, 1, 1, 1, 0, 0])
        var ten = eight
        ten[4] = 2; ten[6] = 0xa2
        #expect(try !NativeVP9Configuration(eight).tenBit)
        #expect(try NativeVP9Configuration(ten).tenBit)
        for size in 0..<12 {
            #expect(throws: (any Error).self) { try NativeVP9Configuration(Data(eight.prefix(size))) }
        }
        for (index, value): (Int, UInt8) in [(0, 0), (4, 1), (6, 0xa2), (6, 0x86), (10, 1)] {
            var bad = eight; bad[index] = value
            #expect(throws: (any Error).self) { try NativeVP9Configuration(bad) }
        }
    }

    @Test func sharedMemoryCleanupRejectsNamesOutsideItsNamespace() {
        for name in ["", "video", "/video", "/tovd../elsewhere", "/tovd.\u{0}", "/tovd." + String(repeating: "x", count: 32)] {
            #expect(throws: (any Error).self) { try NativeVideoSharedMemory.unlinkIfOwned(name: name) }
        }
    }
}
