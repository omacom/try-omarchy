import AppKit
import Foundation

struct GuestBootFixReport: Codable, Equatable {
    static let componentNames = ["clipboard", "screensaver", "alacritty", "power", "clock", "holds",
                                 "lock", "touch-id", "onepassword", "battery", "integrations", "desktop", "ghostty"]
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

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4096 else { throw HelperError.io("boot fixes report exceeds limit") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schema == 1, value.type == "boot-fixes",
              value.identity.count == 64,
              value.identity.allSatisfy({ "0123456789abcdef".contains($0) }),
              ["checking", "running", "complete", "skipped", "failed", "recovery-required", "unconfirmed"].contains(value.state),
              [Set(componentNames), Set(componentNames.filter { $0 != "ghostty" }),
               Set(["clipboard", "screensaver", "alacritty"])].contains(Set(value.components.keys)),
              value.components.values.allSatisfy({ ["current", "applied", "preserved", "unavailable", "pending", "failed"].contains($0) }),
              value.state != "complete" || !value.components.values.contains(where: { ["pending", "failed"].contains($0) })
        else { throw HelperError.io("invalid boot fixes report") }
        return value
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

    var detail: String {
        let names = ["clipboard": "Clipboard", "screensaver": "Screensaver", "alacritty": "Alacritty workaround",
                     "power": "Power/menu plugins", "clock": "Clock recovery", "holds": "Update compatibility holds",
                     "lock": "Lock-screen password policy", "touch-id": "Touch ID support",
                     "onepassword": "Existing 1Password integration", "battery": "Mac battery",
                     "integrations": "Integration setup and status", "desktop": "Pinch input and Apps/menu entries",
                     "ghostty": "Ghostty terminal installer"]
        let labels = ["current": "already current or not needed", "applied": "applied and verified",
                      "preserved": "customized or unsupported files preserved",
                      "unavailable": "skipped · required tools or runtime unavailable", "pending": "pending",
                      "failed": "failed · previous installation kept"]
        return Self.componentNames.filter { components[$0] != nil }.map {
            "\(names[$0]!): \(labels[components[$0] ?? "pending"]!)"
        }.joined(separator: "\n")
    }

    func summary(expectedIdentity: String?) -> String {
        guard let expectedIdentity else { return "VM fix bundle unavailable" }
        return identity == expectedIdentity ? summary : "VM fixes available · last check used an older bundle"
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

    static func url(storageRoot: URL?) -> URL? {
        guard let integrationURL = GuestIntegrationCache.url(storageRoot: storageRoot) else { return nil }
        return integrationURL.deletingLastPathComponent().appendingPathComponent(
            integrationURL.lastPathComponent.replacingOccurrences(of: "integration-status-", with: "boot-fixes-"))
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
        // Unknown disks and changed bundles get a check during normal
        // boot. Only that bundle's actual result can establish work to review.
        guard let expectedIdentity, let cache = read(cacheURL),
              cache.report.identity == expectedIdentity else { return false }
        return cache.report.needsUpdate
    }

    static func needsReview(cacheURL: URL?, expectedIdentity: String?, manuallyRequested: Bool = false) -> Bool {
        guard let cacheURL, let expectedIdentity, let cache = read(cacheURL),
              cache.report.identity == expectedIdentity, cache.report.needsUpdate else { return false }
        // Older failed/interrupted attempts also stay manual. Their marker is
        // retained before a later boot replaces the result with pending work.
        if manuallyRequested { return true }
        if cache.report.updateWasAttempted { return false }
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: reviewURL(cacheURL: cacheURL, identity: expectedIdentity).path)
        return attributes?[.type] as? FileAttributeType != .typeRegular
            || (attributes?[.size] as? NSNumber)?.intValue != 0
    }

    static func recordReview(cacheURL: URL?, identity: String?) throws {
        guard let cacheURL, let identity, let cache = read(cacheURL), cache.report.identity == identity else { return }
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

@MainActor
enum GuestBootFixPrompt {
    static func review() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Update VM?"
        alert.informativeText = """
            Try Omarchy will verify and try to apply these compatible fixes:

            • Clipboard fixes for large selections.
            • Screensaver layout and cursor helper fixes.
            • Remove the old Alacritty software-rendering workaround when supported.
            • Power/menu plugin fixes, clock recovery, and update compatibility holds.
            • Missing lock-screen password policy, pinch input, and stale Apps entries.
            • Fix the Ghostty installer so you can install it from the terminal menu.
            • Integration setup and Touch ID support, without enabling biometrics.
            • Existing 1Password support and the Mac battery integration. Battery builds use your current kernel and require matching headers and existing build tools.

            The kernel and customized files are preserved. Your settings and personal files are kept, and updates will rollback or be skipped in case of failure.
            """
        alert.addButton(withTitle: "Update and Launch")
        alert.addButton(withTitle: "Skip and Launch")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    static func skip() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Launch without these VM fixes?"
        alert.informativeText = "The listed VM fixes and integration updates will not be applied to this disk. Existing issues may remain. You can update on a later launch. Interrupted updates still recover their original files."
        alert.addButton(withTitle: "Go Back")
        alert.addButton(withTitle: "Skip and Launch")
        return alert
    }
}
