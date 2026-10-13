import Darwin
import Foundation

struct VMTransferProgress: Codable, Equatable {
    enum Phase: String, Codable { case checking, copying, verifying, finishing }
    let phase: Phase
    var completedBytes: Int64 = 0
    var totalBytes: Int64 = 0

    static let prefix = "try-omarchy-transfer:"
    var fraction: Double? {
        guard phase == .verifying, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }
    var title: String {
        switch phase {
        case .checking: return "Checking the selected VM and destination…"
        case .copying: return "Copying the selected VM…"
        case .verifying: return "Verifying the copied VM…"
        case .finishing: return "Finishing the move…"
        }
    }
    var line: String {
        Self.prefix + String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self) + "\n"
    }
}

/// The helper's stderr carries bounded progress records alongside real errors.
/// Reads may split a UTF-8 character or a JSON record at any byte boundary.
struct VMTransferOutput {
    private var buffer = Data()
    private(set) var errorMessage = ""

    mutating func append(_ data: Data, finished: Bool = false) -> [VMTransferProgress] {
        buffer.append(data)
        var updates: [VMTransferProgress] = []
        while let newline = buffer.firstIndex(of: 10) {
            consume(Data(buffer[..<newline]), into: &updates)
            buffer.removeSubrange(...newline)
        }
        if finished, !buffer.isEmpty {
            consume(buffer, into: &updates)
            buffer.removeAll()
        } else if buffer.count > 16_384 {
            // A malformed child cannot grow the parent's memory without bound.
            consume(Data(buffer.prefix(8192)), into: &updates)
            buffer.removeAll()
        }
        return updates
    }

    /// POSIX reads return currently available pipe bytes. Foundation's
    /// length-based reads can wait for a whole buffer or EOF on a pipe.
    static func read(from handle: FileHandle, progress: (VMTransferProgress) -> Void) throws -> String {
        var output = Self()
        var bytes = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(handle.fileDescriptor, buffer.baseAddress, buffer.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw HelperError.io("Could not read VM transfer progress (errno \(errno)).")
            }
            if count == 0 {
                output.append(Data(), finished: true).forEach(progress)
                return output.errorMessage
            }
            output.append(Data(bytes.prefix(count))).forEach(progress)
        }
    }

    private mutating func consume(_ data: Data, into updates: inout [VMTransferProgress]) {
        let line = String(decoding: data, as: UTF8.self)
        if line.hasPrefix(VMTransferProgress.prefix) {
            let payload = Data(line.dropFirst(VMTransferProgress.prefix.count).utf8)
            if let update = try? JSONDecoder().decode(VMTransferProgress.self, from: payload),
               update.completedBytes >= 0, update.totalBytes >= 0,
               update.completedBytes <= update.totalBytes {
                updates.append(update)
            }
            return
        }
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            errorMessage = String((errorMessage + (errorMessage.isEmpty ? "" : "\n") + text).suffix(8192))
        }
    }
}
