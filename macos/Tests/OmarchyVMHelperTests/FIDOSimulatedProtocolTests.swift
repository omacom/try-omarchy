import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Simulated FIDO wire properties")
struct FIDOSimulatedProtocolTests {
    private func stream(_ generator: inout FIDOSimulatedGenerator, reports: Int) -> [FIDOFrame] {
        [.hello(Array(0..<16)), .ready(Array(0..<16)), .ping] + (0..<reports).map { _ in FIDOFrame.report(generator.report()) } + [.pong, .bye]
    }

    @Test("independent golden vectors agree with the host serializer and parser")
    func goldenVectors() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("tests/fixtures/fido-wire-vectors.json"))
        let vectors = try JSONDecoder().decode([Vector].self, from: data)
        for vector in vectors {
            let payload = try bytes(vector.payloadHex)
            let expected = try bytes(vector.wireHex)
            let frame: FIDOFrame
            switch vector.kind {
            case 1: frame = .hello(payload)
            case 2: frame = .ready(payload)
            case 3: frame = .report(payload)
            case 4: frame = .ping
            case 5: frame = .pong
            default: frame = .bye
            }
            #expect(frame.bytes == expected)
            var reader = FIDOFrameReader()
            #expect(try reader.feed(expected) == [frame])
            try reader.finish()
        }
        #expect(vectors.count == 13)
        print("FIDO_SIM_CASES golden_vectors=\(vectors.count)")
    }

    @Test("valid seeded streams preserve every report through arbitrary transport chunks")
    func seededFragmentation() throws {
        var generator = FIDOSimulatedGenerator(seed: FIDOSimulatedFixtures.seed)
        var splitCases = 0
        var seededCases = 0
        for index in 0..<64 {
            let frames = stream(&generator, reports: 1 + index % 8)
            let wire = frames.flatMap(\.bytes)
            var coalesced = FIDOFrameReader()
            #expect(try coalesced.feed(wire) == frames)
            try coalesced.finish()
            if index < 16 {
                for cut in 0...wire.count {
                    var reader = FIDOFrameReader()
                    let prefix = try reader.feed(Array(wire.prefix(cut)))
                    let suffix = try reader.feed(Array(wire.dropFirst(cut)))
                    #expect(prefix + suffix == frames)
                    try reader.finish()
                    splitCases += 1
                }
            }
            for _ in 0..<8 {
                var reader = FIDOFrameReader()
                var result: [FIDOFrame] = []
                var offset = 0
                while offset < wire.count {
                    let size = min(wire.count - offset, 1 + Int(generator.next() % 97))
                    result += try reader.feed(Array(wire[offset..<(offset + size)]))
                    #expect(try reader.feed([]).isEmpty)
                    offset += size
                }
                try reader.finish()
                #expect(result == frames)
                seededCases += 1
            }
        }
        #expect(splitCases > 5_840)
        #expect(seededCases == 512)
        print("FIDO_SIM_CASES wire_every_split=\(splitCases) wire_seeded_chunks=\(seededCases) wire_coalesced=64")
    }

    @Test("every single-byte invalid header mutation rejects before a payload arrives")
    func headerMutations() {
        var cases = 0
        let hello: [UInt8] = [0x54, 0x4f, 0x46, 0x44, 2, 1, 0, 16]
        for offset in 0..<5 {
            for value in UInt8.min...UInt8.max where value != hello[offset] {
                var header = hello
                header[offset] = value
                var reader = FIDOFrameReader()
                #expect(throws: (any Error).self) { try reader.feed(FIDOFrame.record(header)) }
                cases += 1
            }
        }
        for kind in UInt8.min...UInt8.max where !(1...6).contains(kind) {
            var header = hello
            header[5] = kind
            var reader = FIDOFrameReader()
            #expect(throws: (any Error).self) { try reader.feed(FIDOFrame.record(header)) }
            cases += 1
        }
        for kind: UInt8 in 1...6 {
            let size: UInt8 = kind <= 2 ? 16 : kind == 3 ? 64 : 0
            let header: [UInt8] = [0x54, 0x4f, 0x46, 0x44, 2, kind, 0, size]
            for value in UInt8.min...UInt8.max {
                if value != 0 {
                    var changed = header
                    changed[6] = value
                    var reader = FIDOFrameReader()
                    #expect(throws: (any Error).self) { try reader.feed(FIDOFrame.record(changed)) }
                    cases += 1
                }
                if value != size {
                    var changed = header
                    changed[7] = value
                    var reader = FIDOFrameReader()
                    #expect(throws: (any Error).self) { try reader.feed(FIDOFrame.record(changed)) }
                    cases += 1
                }
            }
        }
        #expect(cases == 4_585)
        print("FIDO_SIM_CASES invalid_headers=\(cases)")
    }

    @Test("EOF accepts complete prefixes and rejects every unfinished frame")
    func truncatedPrefixes() throws {
        var generator = FIDOSimulatedGenerator(seed: FIDOSimulatedFixtures.seed)
        let frames = stream(&generator, reports: 3)
        let wire = frames.flatMap(\.bytes)
        var completeLengths = Set([0])
        var size = 0
        for frame in frames { size += frame.bytes.count; completeLengths.insert(size) }
        for cut in 0...wire.count {
            var reader = FIDOFrameReader()
            let decoded = try reader.feed(Array(wire.prefix(cut)))
            #expect(decoded.flatMap(\.bytes) == Array(wire.prefix(decoded.flatMap(\.bytes).count)))
            if completeLengths.contains(cut) {
                try reader.finish()
            } else {
                #expect(throws: (any Error).self) { try reader.finish() }
            }
        }
        var reader = FIDOFrameReader()
        let atLimit = (0..<407).flatMap { _ in FIDOFrame.ping.bytes } + FIDOFrame.hello(Array(0..<16)).bytes
        #expect(atLimit.count == 4096)
        #expect(try reader.feed(atLimit) == [FIDOFrame](repeating: .ping, count: 407) + [.hello(Array(0..<16))])
        try reader.finish()
        #expect(throws: (any Error).self) { try reader.feed(atLimit + [0x54]) }
        try reader.finish()
        print("FIDO_SIM_CASES eof_prefixes=\(wire.count + 1) read_limit_positive=1 read_limit_negative=1")
    }

    @Test("bounded output preserves FIFO bytes across partial drains and failed appends")
    func outputBufferTransactions() throws {
        var generator = FIDOSimulatedGenerator(seed: FIDOSimulatedFixtures.seed)
        let frame = FIDOFrame.report(generator.report())
        let original = frame.bytes + FIDOFrame.ping.bytes
        for cut in 0...original.count {
            var output = FIDOOutputBuffer()
            try output.append(frame)
            try output.append(.ping)
            output.consume(cut)
            try output.append(.pong)
            #expect(output.bytes == Array(original.dropFirst(cut)) + FIDOFrame.pong.bytes)
        }
        var full = FIDOOutputBuffer()
        for _ in 0..<(FIDOOutputBuffer.limit / FIDOFrame.ping.bytes.count) { try full.append(.ping) }
        let before = full.bytes
        #expect(before.count == FIDOOutputBuffer.limit / FIDOFrame.ping.bytes.count * FIDOFrame.ping.bytes.count)
        for extra in [FIDOFrame.ready(Array(0..<16)), frame, .bye] {
            #expect(throws: (any Error).self) { try full.append(extra) }
            #expect(full.bytes == before)
        }
        full.consume(frame.bytes.count)
        try full.append(frame)
        #expect(full.bytes == Array(before.dropFirst(frame.bytes.count)) + frame.bytes)
        print("FIDO_SIM_CASES output_partial_drains=\(original.count + 1) output_overflow_transactions=3")
    }

    private struct Vector: Decodable {
        let kind: Int
        let payloadHex: String
        let wireHex: String

        enum CodingKeys: String, CodingKey {
            case kind
            case payloadHex = "payload_hex"
            case wireHex = "wire_hex"
        }
    }

    private func bytes(_ hex: String) throws -> [UInt8] {
        try #require(hex.count.isMultiple(of: 2))
        let values = Array(hex)
        return try stride(from: 0, to: values.count, by: 2).map {
            try #require(UInt8(String(values[$0...($0 + 1)]), radix: 16))
        }
    }
}
