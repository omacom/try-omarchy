import CryptoKit
import Foundation

/// Shared with the guest's reviewed repair planners; IDs name existing handlers.
struct GuestBootFixCatalog: Decodable {
    struct Feature: Decodable, Equatable {
        let title: String
        let icon: String
    }

    struct Migration: Decodable {
        let id: String
        let revision: Int
        let title: String
        let icon: String
        let group: String?
        let note: String?
    }

    let schema: Int
    let groups: [String: Feature]
    let migrations: [Migration]

    var componentIDs: [String] { migrations.map(\.id) }

    var features: [Feature] {
        var seen = Set<String>()
        return migrations.compactMap { migration in
            guard seen.insert(migration.group ?? migration.id).inserted else { return nil }
            return migration.group.flatMap { groups[$0] }
                ?? Feature(title: migration.title, icon: migration.icon)
        }
    }

    var notes: String { migrations.compactMap(\.note).joined(separator: " ") }

    static let bundled: Self? = {
        guard let resources = Bundle.main.resourceURL else { return nil }
        return try? load(payload: resources.appendingPathComponent("guest-settings"))
    }()

    static func load(payload: URL) throws -> Self {
        struct Manifest: Decodable { let files: [String: String] }
        let manifest = try JSONDecoder().decode(Manifest.self,
            from: Data(contentsOf: payload.appendingPathComponent("fixes.json")))
        let data = try Data(contentsOf: payload.appendingPathComponent("catalog.json"))
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard manifest.files["catalog.json"] == digest else {
            throw HelperError.io("VM update catalog does not match its bundle")
        }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 32768 else { throw HelperError.io("VM update catalog exceeds limit") }
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        func identifier(_ value: String) -> Bool {
            value.range(of: "^[a-z][a-z0-9-]{0,47}$", options: .regularExpression) != nil
        }
        func text(_ value: String, limit: Int) -> Bool {
            !value.isEmpty && value.count <= limit
                && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
                && value.rangeOfCharacter(from: .controlCharacters) == nil
        }
        func icon(_ value: String) -> Bool {
            value.count <= 64 && value.range(of: "^[a-z0-9]+(?:[.-][a-z0-9]+)*$", options: .regularExpression) != nil
        }
        let ids = Set(catalog.componentIDs)
        let usedGroups = Set(catalog.migrations.compactMap(\.group))
        guard catalog.schema == 1, (1...32).contains(catalog.migrations.count),
              catalog.groups.count <= 32, ids.count == catalog.migrations.count,
              ids.isDisjoint(with: catalog.groups.keys), usedGroups == Set(catalog.groups.keys),
              catalog.groups.allSatisfy({ identifier($0.key) && text($0.value.title, limit: 80) && icon($0.value.icon) }),
              catalog.migrations.allSatisfy({
                  identifier($0.id) && (1...65535).contains($0.revision)
                      && text($0.title, limit: 80) && icon($0.icon)
                      && ($0.note.map { text($0, limit: 240) } ?? true)
              }) else { throw HelperError.io("invalid VM update catalog") }
        return catalog
    }
}
