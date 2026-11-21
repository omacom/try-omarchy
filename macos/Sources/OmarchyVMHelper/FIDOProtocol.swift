import Foundation

enum FIDOFrame: Equatable {
    case hello([UInt8])
    case ready([UInt8])
    case report([UInt8])
    case ping
    case pong
    case bye

    var bytes: [UInt8] {
        let kind: UInt8
        var payload: [UInt8] = []
        switch self {
        case .hello(let nonce): kind = 1; payload = nonce
        case .ready(let nonce): kind = 2; payload = nonce
        case .report(let report): kind = 3; payload = report
        case .ping: kind = 4
        case .pong: kind = 5
        case .bye: kind = 6
        }
        return Self.record([0x54, 0x4f, 0x46, 0x44, 2, kind, 0, UInt8(payload.count)] + payload)
    }

    static func record(_ bytes: [UInt8]) -> [UInt8] {
        [0x7e] + bytes.flatMap { (0x7d...0x7f).contains($0) ? [0x7d, $0 ^ 0x20] : [$0] } + [0x7f]
    }
}

struct FIDOFrameReader {
    private var buffer: [UInt8] = []
    private var started = false
    private var escaped = false

    mutating func feed(_ bytes: [UInt8]) throws -> [FIDOFrame] {
        guard bytes.count <= 4096 else { throw HelperError.io("FIDO read exceeds 4 KiB") }
        var frames: [FIDOFrame] = []
        for byte in bytes {
            if byte == 0x7e {
                buffer.removeAll(keepingCapacity: true)
                started = true
                escaped = false
                continue
            }
            guard started else { continue }
            if byte == 0x7f {
                guard !escaped, buffer.count >= 8, buffer.count == 8 + Int(buffer[7]) else {
                    throw HelperError.io("incomplete FIDO record")
                }
                switch buffer[5] {
                case 1: frames.append(.hello(Array(buffer.dropFirst(8))))
                case 2: frames.append(.ready(Array(buffer.dropFirst(8))))
                case 3: frames.append(.report(Array(buffer.dropFirst(8))))
                case 4: frames.append(.ping)
                case 5: frames.append(.pong)
                default: frames.append(.bye)
                }
                buffer.removeAll(keepingCapacity: true)
                started = false
                continue
            }
            if byte == 0x7d, !escaped {
                escaped = true
                continue
            }
            if escaped {
                guard (0x5d...0x5f).contains(byte) else { throw HelperError.io("invalid FIDO escape") }
            }
            buffer.append(escaped ? byte ^ 0x20 : byte)
            escaped = false
            if buffer.count >= 8 {
                let kind = buffer[5]
                let size = kind <= 2 ? 16 : kind == 3 ? 64 : 0
                guard Array(buffer.prefix(5)) == [0x54, 0x4f, 0x46, 0x44, 2],
                      (1...6).contains(kind), buffer[6] == 0, Int(buffer[7]) == size,
                      buffer.count <= 8 + size else { throw HelperError.io("invalid FIDO frame") }
            }
        }
        return frames
    }

    func finish() throws {
        guard !started else { throw HelperError.io("FIDO peer disconnected mid-frame") }
    }
}

struct FIDOOutputBuffer {
    static let limit = 64 * 256
    private(set) var bytes: [UInt8] = []

    mutating func append(_ frame: FIDOFrame) throws {
        let message = frame.bytes
        guard bytes.count + message.count <= Self.limit else {
            throw HelperError.io("FIDO peer is not draining its reports")
        }
        bytes.append(contentsOf: message)
    }

    mutating func consume(_ count: Int) {
        bytes.removeFirst(count)
    }
}

protocol FIDOReportDevice: AnyObject {
    func write(_ report: [UInt8]) throws
    func close()
}

struct FIDOPendingRequests {
    private struct Pending {
        let command: UInt8
        var remaining: Int?
        var sequence: UInt8 = 0
    }

    private var requests: [UInt32: Pending] = [:]

    mutating func sent(_ report: [UInt8]) throws {
        guard report.count == 64 else { throw HelperError.io("invalid FIDO report size") }
        guard report[4] & 0x80 != 0 else { return }
        let cid = Self.channel(report)
        let command = report[4]
        if command == 0x86 { requests.removeValue(forKey: cid); return }
        guard cid != 0, cid != UInt32.max, command != 0x91 else { return }
        guard requests[cid] != nil || requests.count < 16 else {
            throw HelperError.io("too many outstanding FIDO channels")
        }
        requests[cid] = Pending(command: command)
    }

    mutating func received(_ report: [UInt8]) {
        let cid = Self.channel(report)
        guard var pending = requests[cid] else { return }
        if report[4] == 0xbb { return }
        if report[4] == 0xbf {
            requests.removeValue(forKey: cid)
            return
        }
        if report[4] & 0x80 != 0 {
            guard report[4] == pending.command else { return }
            pending.remaining = max(0, Int(report[5]) * 256 + Int(report[6]) - 57)
            pending.sequence = 0
        } else {
            guard let remaining = pending.remaining, report[4] == pending.sequence else { return }
            pending.remaining = max(0, remaining - 59)
            pending.sequence &+= 1
        }
        if pending.remaining == 0 {
            requests.removeValue(forKey: cid)
        } else {
            requests[cid] = pending
        }
    }

    func cancellationReports(nonce: [UInt8]) -> [[UInt8]] {
        precondition(nonce.count == 8)
        return requests.keys.sorted().flatMap { cid -> [[UInt8]] in
            let channel: [UInt8] = [UInt8(cid >> 24), UInt8(truncatingIfNeeded: cid >> 16),
                                   UInt8(truncatingIfNeeded: cid >> 8), UInt8(truncatingIfNeeded: cid)]
            var messages: [[UInt8]] = []
            if requests[cid]?.command == 0x90 {
                messages.append(channel + [0x91, 0, 0] + [UInt8](repeating: 0, count: 57))
            }
            messages.append(channel + [0x86, 0, 8] + nonce + [UInt8](repeating: 0, count: 49))
            return messages
        }
    }

    private static func channel(_ report: [UInt8]) -> UInt32 {
        report.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

final class FIDOForwardingSession {
    private let openDevice: () throws -> FIDOReportDevice
    private var device: FIDOReportDevice?
    private var pending = FIDOPendingRequests()
    private(set) var isReady = false
    private(set) var isClosed = false

    init(openDevice: @escaping () throws -> FIDOReportDevice) {
        self.openDevice = openDevice
    }

    deinit { close() }

    func receive(_ frame: FIDOFrame) throws -> FIDOFrame? {
        do { return try handle(frame) }
        catch { close(); throw error }
    }

    private func handle(_ frame: FIDOFrame) throws -> FIDOFrame? {
        guard !isClosed else { throw HelperError.io("FIDO session is closed") }
        if !isReady {
            guard case .hello(let nonce) = frame, nonce.count == 16 else { throw HelperError.io("FIDO guest must negotiate before device access") }
            device = try openDevice()
            isReady = true
            return .ready(nonce)
        }
        switch frame {
        case .report(let report):
            try pending.sent(report)
            try device?.write(report)
            return nil
        case .ping:
            return .pong
        case .bye:
            close()
            return nil
        default:
            throw HelperError.io("unexpected FIDO guest message")
        }
    }

    func receivedReport(_ report: [UInt8]) throws -> FIDOFrame {
        guard isReady, !isClosed, report.count == 64 else {
            throw HelperError.io("unexpected FIDO input report")
        }
        pending.received(report)
        return .report(report)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        guard let opened = device else { return }
        device = nil
        let nonce = (0..<8).map { _ in UInt8.random(in: .min ... .max) }
        for report in pending.cancellationReports(nonce: nonce) {
            try? opened.write(report)
        }
        opened.close()
    }
}
