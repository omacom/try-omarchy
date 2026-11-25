import Foundation

/// Splits what the guest writes to a port into lines. A line over the limit is dropped whole.
struct GuestLineBuffer {
    let maximumLineBytes: Int
    private var line = Data()
    private var discarding = false

    init(maximumLineBytes: Int) {
        self.maximumLineBytes = maximumLineBytes
    }

    /// The lines that `data` completes, without their newlines.
    mutating func consume(_ data: some Sequence<UInt8>) -> [Data] {
        var lines: [Data] = []
        for byte in data {
            if byte == 10 {
                if !discarding { lines.append(line) }
                line = Data()
                discarding = false
            } else if !discarding {
                if line.count < maximumLineBytes {
                    line.append(byte)
                } else {
                    line = Data()
                    discarding = true
                }
            }
        }
        return lines
    }
}
