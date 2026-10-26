import Darwin
import Foundation
import Testing
@testable import OmarchyVMHelper
import TryOmarchyKitClient

struct TryOmarchyStorageTests {
    private static let mebibyte = 1_048_576

    private static func isAPFS(_ url: URL) -> Bool {
        var information = statfs()
        guard statfs(url.path, &information) == 0 else { return false }
        return withUnsafeBytes(of: information.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            == "apfs"
    }

    private static func write(_ data: Data, to url: URL, at offset: UInt64 = 0) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private static func randomData(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    @Test func clonedDiskCountsSharedBlocksOnce() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-clone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shell-factory"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shell"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        guard Self.isAPFS(root) else { return }

        let factory = root.appendingPathComponent("shell-factory/factory.img")
        let disk = root.appendingPathComponent("shell/disk.img")
        try Self.write(Self.randomData(4 * Self.mebibyte), to: factory)
        #expect(TryOmarchyStorage.allocatedBytes(at: root) == Int64(4 * Self.mebibyte))

        #expect(clonefile(factory.path, disk.path, 0) == 0)
        #expect(TryOmarchyStorage.allocatedBytes(at: root) == Int64(4 * Self.mebibyte))

        try Self.write(Self.randomData(Self.mebibyte), to: disk, at: UInt64(Self.mebibyte))
        try Self.write(Self.randomData(Self.mebibyte), to: root.appendingPathComponent("shell/efi-vars.fd"))
        #expect(TryOmarchyStorage.allocatedBytes(at: root) == Int64(6 * Self.mebibyte))
    }

    @Test("the default folder is the one the run mode uses when nothing names another")
    func defaultRoot() {
        #expect(TryOmarchyStorage.defaultRoot()?.standardizedFileURL
            == QEMUGPUStorageSpaceEstimate.storageRootURL(environment: [:]))
    }

    @Test("a VM folder takes the size and space checks")
    func folderHasVM() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-moved-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!TryOmarchyStorage.hasVM(at: root))
        #expect(TryOmarchyStorage.requiredFreeBytes(at: root) == TryOmarchyStorage.requiredFreeBytesForNewVM)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shell"), withIntermediateDirectories: true)
        try Self.write(Self.randomData(Self.mebibyte), to: root.appendingPathComponent("shell/disk.img"))
        #expect(TryOmarchyStorage.hasVM(at: root))
        #expect(TryOmarchyStorage.requiredFreeBytes(at: root) == TryOmarchyStorage.requiredFreeBytesForExistingVM)
        #expect(TryOmarchyStorage.allocatedBytes(at: root) >= Int64(Self.mebibyte))
    }
}
