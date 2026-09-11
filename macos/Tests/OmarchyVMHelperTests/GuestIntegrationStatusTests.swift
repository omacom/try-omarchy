import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Guest integration status")
struct GuestIntegrationStatusTests {
    private let identity = String(repeating: "a", count: 64)

    @Test("Only a complete current report can be up to date")
    func states() throws {
        let current = GuestIntegrationReport(schema: 1, version: 1, identity: identity,
            components: ["sudo": "current", "clock": "current", "holds": "current"], paired: true)
        let decoded = try GuestIntegrationReport.decode(JSONEncoder().encode(current))
        #expect(decoded.summary(expectedIdentity: identity) == "Up to date")
        #expect(decoded.summary(expectedIdentity: String(repeating: "b", count: 64)) == "Updates available")
        #expect(decoded.summary(expectedIdentity: nil) == "Bundle status unavailable")
        let unpaired = GuestIntegrationReport(schema: 1, version: 1, identity: identity,
            components: current.components, paired: false)
        #expect(unpaired.summary(expectedIdentity: identity).contains("setup available"))
        let repair = GuestIntegrationReport(schema: 1, version: 1, identity: identity,
            components: ["sudo": "current", "clock": "repair", "holds": "current"], paired: true)
        #expect(repair.summary(expectedIdentity: identity) == "Repair available")
    }

    @Test("Malformed and incomplete guest reports cannot establish status")
    func malformed() {
        for raw in ["{}", "[]", String(repeating: "x", count: 4097),
                    "{\"schema\":1,\"version\":1,\"identity\":\"\(identity)\",\"components\":{},\"paired\":true}"] {
            #expect(throws: (any Error).self) { try GuestIntegrationReport.decode(Data(raw.utf8)) }
        }
    }

    @Test("Newer protocol versions do not trigger a downgrade claim")
    func newer() {
        let report = GuestIntegrationReport(schema: 1, version: 2, identity: identity,
            components: ["sudo": "current", "clock": "current", "holds": "current"], paired: true)
        #expect(report.summary(expectedIdentity: "older") == "Newer guest integration version")
    }

    @Test("Cache stays outside disk inventory and changes when a disk is replaced")
    func diskIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("disks/current")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let disk = directory.appendingPathComponent("rootfs.ext4")
        try Data("first disk".utf8).write(to: disk)
        let first = try #require(GuestIntegrationCache.url(storageRoot: root))
        #expect(first.deletingLastPathComponent().path == root.path)
        try FileManager.default.moveItem(at: disk, to: root.appendingPathComponent("retained-disk"))
        try Data("new disk".utf8).write(to: disk)
        let second = try #require(GuestIntegrationCache.url(storageRoot: root))
        #expect(first != second)
    }

    @Test("No response remains distinct from missing bootstrap")
    func missing() {
        let cache = GuestIntegrationCache(checkedAt: Date(), state: "no-response", report: nil)
        #expect(cache.summary == "Setup or repair may be needed")
        #expect(!cache.summary.contains("missing"))
    }
}
