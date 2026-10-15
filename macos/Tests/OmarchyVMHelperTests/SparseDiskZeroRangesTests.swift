import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Sparse disk zero ranges")
struct SparseDiskZeroRangesTests {
    @Test("zero blocks are deallocated and the contents are unchanged")
    func punchesZeroBlocks() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var data = Data()
        for index in 0..<16 {
            // Alternate 256 KiB of data with 768 KiB of zeros, like a filesystem image.
            data.append(Data((0..<(256 * 1024)).map { UInt8(truncatingIfNeeded: $0 &+ index) | 1 }))
            data.append(Data(count: 768 * 1024))
        }
        data.append(Data([1, 2, 3]))
        try data.write(to: url)
        let punched = try SparseDiskZeroRanges.punch(path: url.path)
        #expect(punched >= 16 * 768 * 1024 - 2 * 65536)
        #expect(try Data(contentsOf: url) == data)
        let allocated = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0
        #expect(allocated < data.count / 2)
    }
}
