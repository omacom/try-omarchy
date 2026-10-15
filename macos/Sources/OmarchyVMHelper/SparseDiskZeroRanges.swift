import Darwin
import Foundation

/// Returns all-zero ranges of a disk image to APFS (`--sparsify PATH`).
///
/// Decompression leaves zero data allocated wherever data and holes alternate
/// finely, as in a filesystem image's free space. Each aligned run of zero
/// blocks is deallocated with `F_PUNCHHOLE`; the file's length and contents
/// are unchanged, so a VM disk cloned from it allocates only what is in use.
enum SparseDiskZeroRanges {
    static let chunkBytes = 1 << 20

    /// Bytes deallocated. Ranges are whole multiples of the filesystem block.
    @discardableResult
    static func punch(path: String, blockBytes: Int? = nil) throws -> Int64 {
        let descriptor = open(path, O_RDWR | O_NOFOLLOW)
        guard descriptor >= 0 else { throw HelperError.io("cannot open \(path): \(String(cString: strerror(errno)))") }
        defer { close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0, information.st_mode & S_IFMT == S_IFREG else {
            throw HelperError.io("\(path) is not a regular file")
        }
        let block = blockBytes ?? max(Int(information.st_blksize), 4096)
        guard block > 0, chunkBytes % block == 0 else { throw HelperError.io("unsupported block size \(block)") }

        var buffer = [UInt8](repeating: 0, count: chunkBytes)
        let zeros = [UInt8](repeating: 0, count: block)
        var offset: Int64 = 0
        var runStart: Int64 = -1
        var punched: Int64 = 0

        func flush(until end: Int64) throws {
            guard runStart >= 0, end > runStart else { runStart = -1; return }
            var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(runStart), fp_length: off_t(end - runStart))
            if fcntl(descriptor, F_PUNCHHOLE, &hole) != 0 {
                throw HelperError.io("cannot deallocate zero blocks in \(path): \(String(cString: strerror(errno)))")
            }
            punched += end - runStart
            runStart = -1
        }

        while true {
            let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, chunkBytes, off_t(offset)) }
            if count < 0 { throw HelperError.io("cannot read \(path): \(String(cString: strerror(errno)))") }
            if count == 0 { break }
            var position = 0
            while position + block <= count {
                let isZero = buffer.withUnsafeBytes { raw in
                    zeros.withUnsafeBytes { memcmp(raw.baseAddress! + position, $0.baseAddress!, block) == 0 }
                }
                let blockOffset = offset + Int64(position)
                if isZero {
                    if runStart < 0 { runStart = blockOffset }
                } else {
                    try flush(until: blockOffset)
                }
                position += block
            }
            // A partial trailing block is never punched.
            if position < count { try flush(until: offset + Int64(position)) }
            offset += Int64(count)
        }
        try flush(until: offset - offset % Int64(block))
        return punched
    }
}
