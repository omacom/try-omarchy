import Foundation

struct GuestBootFixReport: Codable, Equatable {
    // Frozen compatibility with reports written before the shared catalog.
    // New components belong only in the catalog and their guest planners.
    private static let legacyComponentNames = ["clipboard", "screensaver", "alacritty", "power", "clock", "holds",
                                              "lock", "touch-id", "onepassword", "battery", "integrations", "desktop", "ghostty"]
    static var componentNames: [String] { GuestBootFixCatalog.bundled?.componentIDs ?? legacyComponentNames }
    static var pendingComponents: [String: String] { Dictionary(uniqueKeysWithValues: componentNames.map { ($0, "pending") }) }
    let schema: Int
    let type: String
    let identity: String
    let state: String
    let components: [String: String]

    var needsUpdate: Bool {
        switch state {
        case "complete": return false
        case "skipped": return components.values.contains("pending")
        default: return true
        }
    }

    var needsAttention: Bool {
        ["failed", "recovery-required", "unconfirmed"].contains(state)
    }

    var updateWasAttempted: Bool {
        ["checking", "running"].contains(state) || needsAttention
    }

    static func decode(_ data: Data, catalog: GuestBootFixCatalog? = .bundled) throws -> Self {
        guard data.count <= 4096 else { throw HelperError.io("boot fixes report exceeds limit") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schema == 1, value.type == "boot-fixes",
              !value.components.isEmpty,
              value.identity.count == 64,
              value.identity.allSatisfy({ "0123456789abcdef".contains($0) }),
              ["checking", "running", "complete", "skipped", "failed", "recovery-required", "unconfirmed"].contains(value.state),
              [Set(catalog?.componentIDs ?? []), Set(legacyComponentNames), Set(legacyComponentNames.filter { $0 != "ghostty" }),
               Set(["clipboard", "screensaver", "alacritty"])].contains(Set(value.components.keys)),
              value.components.values.allSatisfy({ ["current", "applied", "preserved", "unavailable", "pending", "failed"].contains($0) }),
              value.state != "complete" || !value.components.values.contains(where: { ["pending", "failed"].contains($0) })
        else { throw HelperError.io("invalid boot fixes report") }
        return value
    }

    func matchesComponents(in catalog: GuestBootFixCatalog) -> Bool {
        Set(components.keys) == Set(catalog.componentIDs)
    }

    var summary: String {
        switch state {
        case "checking": return "Waiting for VM fix results…"
        case "running": return "Applying VM fixes…"
        case "complete":
            if components.values.contains("preserved") || components.values.contains("unavailable") {
                return "VM fixes checked · some fixes skipped"
            }
            return components.values.contains("applied") ? "VM fixes applied and verified" : "VM fixes are current"
        case "skipped": return "VM fixes skipped · update available"
        case "failed": return "Some VM fixes failed · affected changes restored"
        case "unconfirmed": return "VM fixes could not be confirmed · retry available"
        default: return "VM fix recovery needs attention"
        }
    }

    var detail: String { detail(catalog: .bundled) }

    func detail(catalog: GuestBootFixCatalog?) -> String {
        let names = Dictionary(uniqueKeysWithValues: (catalog?.migrations ?? []).map { ($0.id, $0.title) })
        let labels = ["current": "already current or not needed", "applied": "applied and verified",
                      "preserved": "customized or unsupported files preserved",
                      "unavailable": "skipped · required tools or runtime unavailable", "pending": "pending",
                      "failed": "failed · previous installation kept"]
        return components.keys.sorted().map {
            "\(names[$0] ?? $0): \(labels[components[$0] ?? "pending"]!)"
        }.joined(separator: "\n")
    }

    func summary(expectedIdentity: String?) -> String {
        guard let expectedIdentity else { return "VM fix bundle unavailable" }
        return identity == expectedIdentity ? summary : "VM fixes available · last check used an older bundle"
    }
}

/// A one-time outcome for an approved update, without the diagnostic report.
struct GuestBootFixResult {
    let title: String
    let message: String
    let isWarning: Bool

    init?(report: GuestBootFixReport, catalog: GuestBootFixCatalog? = .bundled) {
        let names = Dictionary(uniqueKeysWithValues: (catalog?.migrations ?? []).map { ($0.id, $0.title) })
        let skipped = report.components.keys.sorted().filter {
            ["preserved", "unavailable", "pending", "failed"].contains(report.components[$0] ?? "")
        }.map { names[$0] ?? $0 }.joined(separator: ", ")

        switch report.state {
        case "checking", "running": return nil
        case "complete", "skipped":
            if skipped.isEmpty {
                title = "VM update complete"
                message = "Your VM is ready to use."
                isWarning = false
            } else if report.needsUpdate {
                title = "VM update wasn’t completed"
                message = "Some fixes are still pending. You can try again from Update and Launch after shutting down Omarchy."
                isWarning = true
            } else {
                title = "Some items couldn’t be updated"
                message = "Skipped: \(skipped).\n\nCustomized or unsupported items were left unchanged."
                isWarning = true
            }
        case "failed":
            title = "VM update couldn’t finish"
            message = "Affected changes were restored. Shut down Omarchy and use Update and Launch to try again."
            isWarning = true
        case "recovery-required":
            title = "VM update needs recovery"
            message = "Some original files couldn’t be restored. Shut down Omarchy and retry the update before using these integrations. Backups remain in the VM."
            isWarning = true
        case "unconfirmed":
            title = "VM update couldn’t be confirmed"
            message = "No completion result was received. Shut down Omarchy and use Update and Launch to try again."
            isWarning = true
        default:
            title = "VM update wasn’t completed"
            message = "Some fixes are still pending. You can try again from Update and Launch after shutting down Omarchy."
            isWarning = true
        }
    }
}

struct GuestBootFixCache: Codable {
    let checkedAt: Date
    let report: GuestBootFixReport

    static var bundledIdentity: String? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("guest-settings/fixes.json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let identity = object["identity"] as? String,
              identity.count == 64, identity.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return identity
    }

    static func url(storageRoot: URL?, diskURL: URL? = nil) -> URL? {
        guard let storageRoot,
              let attributes = try? FileManager.default.attributesOfItem(
                atPath: (diskURL ?? storageRoot.appendingPathComponent("disks/current/rootfs.ext4")).path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return storageRoot.appendingPathComponent("boot-fixes-\(inode.uint64Value).json")
    }

    static func read(_ url: URL?) -> Self? {
        guard let url, let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 8192,
              let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Self.self, from: data),
              (try? GuestBootFixReport.decode(JSONEncoder().encode(value.report))) != nil else { return nil }
        return value
    }

    static func needsUpdate(cacheURL: URL?, expectedIdentity: String?) -> Bool {
        // Existing disks review a new bundle before their first boot with it.
        // A matching result can establish that its fixes are already current.
        guard cacheURL != nil, let expectedIdentity else { return false }
        guard let cache = read(cacheURL), cache.report.identity == expectedIdentity else { return true }
        if let catalog = GuestBootFixCatalog.bundled, !cache.report.matchesComponents(in: catalog) { return true }
        return cache.report.needsUpdate
    }

    static func needsReview(cacheURL: URL?, expectedIdentity: String?, manuallyRequested: Bool = false) -> Bool {
        guard let cacheURL, let expectedIdentity,
              needsUpdate(cacheURL: cacheURL, expectedIdentity: expectedIdentity) else { return false }
        // Older failed/interrupted attempts also stay manual. Their marker is
        // retained before a later boot replaces the result with pending work.
        if manuallyRequested { return true }
        if let cache = read(cacheURL), cache.report.identity == expectedIdentity,
           cache.report.updateWasAttempted { return false }
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: reviewURL(cacheURL: cacheURL, identity: expectedIdentity).path)
        return attributes?[.type] as? FileAttributeType != .typeRegular
            || (attributes?[.size] as? NSNumber)?.intValue != 0
    }

    static func recordReview(cacheURL: URL?, identity: String?) throws {
        guard let cacheURL, let identity, identity.count == 64,
              identity.allSatisfy({ "0123456789abcdef".contains($0) }) else { return }
        // This is only a reminder acknowledgement, never installation consent.
        try Data().write(to: reviewURL(cacheURL: cacheURL, identity: identity), options: .atomic)
    }

    static func retain(_ report: GuestBootFixReport, cacheURL: URL?) throws {
        guard let cacheURL else { return }
        if let previous = read(cacheURL), previous.report.updateWasAttempted {
            try recordReview(cacheURL: cacheURL, identity: previous.report.identity)
        }
        let value = Self(checkedAt: Date(), report: report)
        try JSONEncoder().encode(value).write(to: cacheURL, options: .atomic)
    }

    private static func reviewURL(cacheURL: URL, identity: String) -> URL {
        cacheURL.deletingPathExtension().appendingPathExtension("\(identity).reviewed")
    }

    /// The shell rechecks this inode under the VM lock before granting consent.
    static func consent(cacheURL: URL?, identity: String?) -> String? {
        guard let cacheURL, let identity,
              let inode = cacheURL.deletingPathExtension().lastPathComponent.split(separator: "-").last,
              !inode.isEmpty, inode.allSatisfy({ $0.isNumber }) else { return nil }
        return "\(identity):\(inode)"
    }
}

enum GuestBootFixChoice { case update, skip, cancel }

enum GuestBootFixLaunchGate {
    static func decide(review: () -> GuestBootFixChoice, confirmSkip: () -> Bool) -> GuestBootFixChoice {
        switch review() {
        case .update: return .update
        case .cancel: return .cancel
        case .skip: return confirmSkip() ? .skip : .cancel
        }
    }
}
