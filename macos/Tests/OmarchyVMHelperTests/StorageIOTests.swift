import CryptoKit
import Darwin
import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Storage I/O")
struct StorageIOTests {
    @Test("Streaming SHA-256 matches known digests, including multiple read buffers")
    func digests() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("abc".utf8).write(to: fixture.file)
        #expect(try StorageIO.sha256(path: fixture.file.path)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        try Data().write(to: fixture.file)
        #expect(try StorageIO.sha256(path: fixture.file.path)
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        let data = Data((0..<(8 * 1024 * 1024 + 123)).map { UInt8(truncatingIfNeeded: $0) })
        try data.write(to: fixture.file)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(try StorageIO.sha256(path: fixture.file.path) == expected)
    }

    @Test("Checkpoints flush files and directories without changing their contents")
    func checkpoints() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try StorageIO.sync(paths: [fixture.file.path, fixture.root.path])
        #expect(try Data(contentsOf: fixture.file) == Data("preserve me".utf8))
        #expect(throws: (any Error).self) {
            try StorageIO.sync(paths: [fixture.root.appendingPathComponent("missing").path])
        }
    }

    @Test("Unsafe paths and special files fail without following links or blocking")
    func unsafePaths() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let alias = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.file)
        #expect(throws: (any Error).self) { try StorageIO.sha256(path: alias.path) }
        #expect(throws: (any Error).self) { try StorageIO.sync(paths: [alias.path]) }
        #expect(throws: (any Error).self) { try StorageIO.sha256(path: fixture.root.path) }
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.linkItem(at: fixture.file, to: alias)
        #expect(throws: (any Error).self) { try StorageIO.sync(paths: [fixture.file.path]) }
        try FileManager.default.removeItem(at: alias)
        #expect(mkfifo(alias.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try StorageIO.sha256(path: alias.path) }
        #expect(throws: (any Error).self) { try StorageIO.sync(paths: [alias.path]) }
        chmod(fixture.file.path, 0o644)
        #expect(throws: (any Error).self) { try StorageIO.sync(paths: [fixture.file.path]) }
        chmod(fixture.root.path, 0o755)
        #expect(throws: (any Error).self) { try StorageIO.sync(paths: [fixture.root.path]) }
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file: URL
        init() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            chmod(root.path, 0o700)
            file = root.appendingPathComponent("disk")
            try Data("preserve me".utf8).write(to: file)
            chmod(file.path, 0o600)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
