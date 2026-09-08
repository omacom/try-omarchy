import Darwin
import Foundation

/// Length-bounded messages on the private virtio channel. All integers are LE.
/// The token is opaque to the bridge and is returned with the decoded picture.
struct NativeVideoMessage {
    static let headerSize = 40
    static let maxPayload = 64 * 1024 * 1024
    static let magic: UInt32 = 0x44564f54 // TOVD
    enum Operation: UInt16 {
        case open = 1, decode = 2, drain = 3, close = 4, release = 5, reset = 6
        case opened = 0x8001, decoded = 0x8002, drained = 0x8003, closed = 0x8004
        case resetComplete = 0x8006
        case frame = 0x8100, error = 0xffff
    }

    var operation: Operation
    var session: UInt32
    var token: UInt64 = 0
    var arg0: UInt32 = 0
    var arg1: UInt32 = 0
    var flags: UInt32 = 0
    var payload = Data()

    func encoded() throws -> Data {
        guard payload.count <= Self.maxPayload else {
            throw HelperError.io("video payload exceeds 64 MiB")
        }
        var data = Data(capacity: Self.headerSize + payload.count)
        Self.append(Self.magic, to: &data)
        Self.append(UInt16(1), to: &data)
        Self.append(operation.rawValue, to: &data)
        Self.append(session, to: &data)
        Self.append(UInt32(payload.count), to: &data)
        Self.append(token, to: &data)
        Self.append(arg0, to: &data)
        Self.append(arg1, to: &data)
        Self.append(flags, to: &data)
        Self.append(UInt32(0), to: &data)
        data.append(payload)
        return data
    }

    static func parseHeader(_ data: Data) throws -> (NativeVideoMessage, Int) {
        guard data.count == headerSize,
              integer(data, at: 0, as: UInt32.self) == magic,
              integer(data, at: 4, as: UInt16.self) == 1,
              integer(data, at: 36, as: UInt32.self) == 0,
              let operation = Operation(rawValue: integer(data, at: 6, as: UInt16.self)) else {
            throw HelperError.io("invalid video protocol header")
        }
        let length = Int(integer(data, at: 12, as: UInt32.self))
        guard length <= maxPayload else { throw HelperError.io("video payload exceeds 64 MiB") }
        return (NativeVideoMessage(
            operation: operation,
            session: integer(data, at: 8, as: UInt32.self),
            token: integer(data, at: 16, as: UInt64.self),
            arg0: integer(data, at: 24, as: UInt32.self),
            arg1: integer(data, at: 28, as: UInt32.self),
            flags: integer(data, at: 32, as: UInt32.self)
        ), length)
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private static func integer<T: FixedWidthInteger>(_ data: Data, at offset: Int, as: T.Type) -> T {
        data.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }

    static func read(from descriptor: Int32, timeoutMilliseconds: Int32? = nil) throws -> NativeVideoMessage? {
        guard let header = try readExactly(headerSize, from: descriptor, allowEOF: true, initialTimeout: timeoutMilliseconds) else { return nil }
        var (message, length) = try parseHeader(header)
        message.payload = try readExactly(length, from: descriptor, allowEOF: false, initialTimeout: 5_000) ?? Data()
        return message
    }

    static func readExactly(_ length: Int, from descriptor: Int32, allowEOF: Bool, initialTimeout: Int32?) throws -> Data? {
        var result = Data(count: length)
        let complete = try result.withUnsafeMutableBytes { bytes -> Bool in
            var offset = 0
            var deadline: UInt64? = initialTimeout.map { DispatchTime.now().uptimeNanoseconds + UInt64($0) * 1_000_000 }
            while offset < length {
                let remaining: Int32
                if let deadline {
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard now < deadline else { throw HelperError.io("video message timed out") }
                    remaining = Int32(min((deadline - now + 999_999) / 1_000_000, UInt64(Int32.max)))
                } else { remaining = -1 }
                var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&item, 1, remaining)
                if ready < 0 && errno == EINTR { continue }
                guard ready > 0 else { throw HelperError.io("video message timed out or polling failed") }
                let count = Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), length - offset)
                if count > 0 {
                    offset += count
                    if deadline == nil { deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000 }
                }
                else if count < 0 && errno == EINTR { continue }
                else if count == 0 && offset == 0 && allowEOF { return false }
                else { throw HelperError.io("video channel closed during a message") }
            }
            return true
        }
        return complete ? result : nil
    }
}

/// Parse hvcC without trusting array counts or NAL lengths from the guest.
struct NativeHEVCConfiguration {
    let parameterSets: [Data]
    let nalLengthSize: Int
    let tenBit: Bool

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 23, bytes.count <= 1024 * 1024, bytes[0] == 1,
              (bytes[17] & 7 == 0 || bytes[17] & 7 == 2),
              bytes[18] & 7 == bytes[17] & 7 else {
            throw HelperError.io("unsupported HEVC configuration; expected 8/10-bit hvcC")
        }
        nalLengthSize = Int(bytes[21] & 3) + 1
        tenBit = (bytes[17] & 7) > 0
        var sets: [Data] = []
        var types = Set<UInt8>()
        var offset = 23
        for _ in 0..<Int(bytes[22]) {
            guard offset + 3 <= bytes.count else { throw HelperError.io("truncated HEVC array") }
            let type = bytes[offset] & 0x3f
            let count = Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2])
            offset += 3
            guard count <= 64 else { throw HelperError.io("too many HEVC parameter sets") }
            for _ in 0..<count {
                guard offset + 2 <= bytes.count else { throw HelperError.io("truncated HEVC NAL length") }
                let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                offset += 2
                guard length >= 2, offset + length <= bytes.count else {
                    throw HelperError.io("truncated HEVC parameter set")
                }
                if [32, 33, 34].contains(type) {
                    guard (bytes[offset] >> 1) & 0x3f == type else {
                        throw HelperError.io("HEVC array type does not match its NAL unit")
                    }
                    sets.append(Data(bytes[offset..<offset + length]))
                    types.insert(type)
                }
                offset += length
            }
        }
        guard offset == bytes.count, types == Set([32, 33, 34]), sets.count <= 64 else {
            throw HelperError.io("HEVC configuration must contain VPS, SPS and PPS")
        }
        parameterSets = sets
    }

    func validatePacket(_ data: Data) throws {
        guard !data.isEmpty else { throw HelperError.io("empty HEVC access unit") }
        var offset = 0
        while offset < data.count {
            guard offset + nalLengthSize <= data.count else { throw HelperError.io("truncated HEVC packet") }
            var length = 0
            for byte in data[offset..<offset + nalLengthSize] { length = length << 8 | Int(byte) }
            offset += nalLengthSize
            guard length >= 2, length <= data.count - offset else {
                throw HelperError.io("invalid HEVC packet NAL length")
            }
            offset += length
        }
    }
}
