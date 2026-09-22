import Darwin
import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Sparse disk growth")
struct SparseDiskGrowthTests {
    @Test("Growing a disk preserves data and allocates only written blocks")
    func sparseGrowth() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try SparseDiskGrowth.grow(path: fixture.disk.path, expectedBytes: 4096, targetBytes: 1 << 30, identity: fixture.identity)
        var info = stat()
        #expect(lstat(fixture.disk.path, &info) == 0)
        #expect(info.st_size == 1 << 30)
        #expect(info.st_blocks * 512 < 1 << 20)
        let handle = try FileHandle(forReadingFrom: fixture.disk)
        defer { try? handle.close() }
        #expect(try handle.read(upToCount: 4096) == fixture.payload)
        try handle.seek(toOffset: (1 << 30) - 4096)
        #expect(try handle.read(upToCount: 4096) == Data(repeating: 0, count: 4096))
    }

    @Test("Changed identity, size, links and unsafe permissions cannot mutate a disk")
    func refusedGrowth() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        func rejected(path: String? = nil, old: Int64 = 4096, target: Int64 = 1 << 30, identity: String? = nil) {
            #expect(throws: (any Error).self) {
                try SparseDiskGrowth.grow(path: path ?? fixture.disk.path, expectedBytes: old,
                    targetBytes: target, identity: identity ?? fixture.identity)
            }
        }
        rejected(identity: "0:0")
        rejected(old: 4095)
        rejected(target: 4095)
        rejected(target: 8193 << 30)
        let alias = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.disk)
        rejected(path: alias.path)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.linkItem(at: fixture.disk, to: alias)
        rejected()
        try FileManager.default.removeItem(at: alias)
        chmod(fixture.disk.path, 0o644)
        rejected()
        #expect(try Data(contentsOf: fixture.disk) == fixture.payload)
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let disk: URL
        let identity: String
        let payload = Data(repeating: 42, count: 4096)
        init() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            disk = root.appendingPathComponent("disk")
            try payload.write(to: disk)
            chmod(disk.path, 0o600)
            var info = stat()
            guard lstat(disk.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
            identity = "\(info.st_dev):\(info.st_ino)"
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
