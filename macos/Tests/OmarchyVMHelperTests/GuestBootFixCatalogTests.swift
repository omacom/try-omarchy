import CryptoKit
import Foundation
import Testing
@testable import OmarchyVMHelper

func migrationCatalogFixture() throws -> GuestBootFixCatalog {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    return try GuestBootFixCatalog.decode(Data(contentsOf: root.appendingPathComponent("guest/migrations/catalog.json")))
}

@Suite("VM migration catalog")
struct GuestBootFixCatalogTests {
    private let source = """
        {"schema":1,"groups":{"input":{"title":"Input fixes","icon":"keyboard"}},"migrations":[
          {"id":"keyboard","revision":2,"title":"Keyboard","icon":"keyboard","group":"input"},
          {"id":"mouse","revision":1,"title":"Mouse","icon":"computermouse","group":"input"},
          {"id":"new-camera","revision":1,"title":"New camera support","icon":"camera","note":"Camera setup stays optional."}
        ]}
        """

    @Test("Catalog additions flow into review and result labels without Swift registration")
    func generatedPresentation() throws {
        let catalog = try GuestBootFixCatalog.decode(Data(source.utf8))
        #expect(catalog.componentIDs == ["keyboard", "mouse", "new-camera"])
        #expect(catalog.features == [
            .init(title: "Input fixes", icon: "keyboard"), .init(title: "New camera support", icon: "camera")
        ])
        #expect(catalog.notes == "Camera setup stays optional.")
        let report = GuestBootFixReport(schema: 1, type: "boot-fixes", identity: String(repeating: "a", count: 64),
            state: "complete", components: ["keyboard": "current", "mouse": "applied", "new-camera": "unavailable"])
        #expect(try GuestBootFixReport.decode(JSONEncoder().encode(report), catalog: catalog) == report)
        let result = try #require(GuestBootFixResult(report: report, catalog: catalog))
        #expect(result.message.contains("New camera support"))
        #expect(!result.message.contains("Keyboard"))
        #expect(!result.message.contains("Mouse"))
    }

    @Test("A live result must cover the catalog even when a legacy cache is readable")
    func reportCoverage() throws {
        let catalog = try migrationCatalogFixture()
        let old = GuestBootFixReport(schema: 1, type: "boot-fixes", identity: String(repeating: "a", count: 64),
            state: "complete", components: ["clipboard": "current", "screensaver": "current", "alacritty": "current"])
        #expect(try GuestBootFixReport.decode(JSONEncoder().encode(old), catalog: catalog) == old)
        #expect(!old.matchesComponents(in: catalog))
        let current = GuestBootFixReport(schema: 1, type: "boot-fixes", identity: old.identity,
            state: "complete", components: Dictionary(uniqueKeysWithValues: catalog.componentIDs.map { ($0, "current") }))
        #expect(current.matchesComponents(in: catalog))
    }

    @Test("Missing, altered, or invalid catalogs cannot supply the consent screen")
    func bundledIntegrity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: (any Error).self) { try GuestBootFixCatalog.load(payload: directory) }
        let data = Data(source.utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try JSONEncoder().encode(["files": ["catalog.json": digest]])
            .write(to: directory.appendingPathComponent("fixes.json"))
        let url = directory.appendingPathComponent("catalog.json")
        try data.write(to: url)
        #expect(try GuestBootFixCatalog.load(payload: directory).componentIDs.count == 3)
        try Data(source.replacingOccurrences(of: "New camera support", with: "Unexpected repair").utf8).write(to: url)
        #expect(throws: (any Error).self) { try GuestBootFixCatalog.load(payload: directory) }
        for invalid in [source.replacingOccurrences(of: "\"revision\":2", with: "\"revision\":0"),
                        source.replacingOccurrences(of: "\"id\":\"mouse\"", with: "\"id\":\"keyboard\""),
                        source.replacingOccurrences(of: "\"group\":\"input\"", with: "\"group\":\"missing\""),
                        source.replacingOccurrences(of: "\"schema\":1", with: "\"schema\":2")] {
            #expect(throws: (any Error).self) { try GuestBootFixCatalog.decode(Data(invalid.utf8)) }
        }
        #expect(throws: (any Error).self) { try GuestBootFixCatalog.decode(Data(repeating: 32, count: 32769)) }
    }
}
