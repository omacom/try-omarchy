import AppKit
import Foundation

struct GuestBootFixReport: Codable, Equatable {
    let schema: Int
    let type: String
    let identity: String
    let state: String
    let components: [String: String]

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4096 else { throw HelperError.io("boot fixes report exceeds limit") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schema == 1, value.type == "boot-fixes",
              value.identity.count == 64,
              value.identity.allSatisfy({ "0123456789abcdef".contains($0) }),
              ["checking", "running", "complete", "skipped", "failed", "recovery-required", "unconfirmed"].contains(value.state),
              Set(value.components.keys) == ["clipboard", "screensaver", "alacritty"],
              value.components.values.allSatisfy({ ["current", "applied", "preserved", "unavailable", "pending"].contains($0) }),
              value.state != "complete" || !value.components.values.contains("pending")
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
        case "failed": return "VM fixes failed · previous files restored"
        case "unconfirmed": return "VM fixes could not be confirmed · retry available"
        default: return "VM fix recovery needs attention"
        }
    }

    var detail: String {
        let names = ["clipboard": "Clipboard", "screensaver": "Screensaver", "alacritty": "Alacritty workaround"]
        let labels = ["current": "already current or not needed", "applied": "applied and verified",
                      "preserved": "customized or unsupported files preserved",
                      "unavailable": "required runtime unavailable", "pending": "pending"]
        return ["clipboard", "screensaver", "alacritty"].map {
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
        guard cacheURL != nil, let expectedIdentity else { return false }
        guard let cache = read(cacheURL) else { return true }
        return cache.report.identity != expectedIdentity || cache.report.state != "complete"
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
        alert.messageText = "Update this VM before launching?"
        alert.informativeText = """
            On this boot, Try Omarchy will check and apply these compatible fixes:

            • Clipboard fixes for large selections.
            • Screensaver layout and cursor helper fixes.
            • Remove the old Alacritty software-rendering workaround when supported.

            Only recognized stock files are changed. Customized files are preserved. Original files are backed up, changes are verified, and a failed file update is restored. Interrupted updates are recovered on the next boot.

            Your applications and personal files are kept. This does not update packages, the kernel, or Touch ID authentication. Existing boot settings and shared-folder safety still apply if you skip.
            """
        alert.addButton(withTitle: "Update and Launch")
        alert.addButton(withTitle: "Skip")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    static func skip() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Launch without these VM fixes?"
        alert.informativeText = "The optional clipboard, screensaver, and Alacritty fixes will not be applied to this disk. Existing issues may remain. You can update on a later launch. Interrupted updates still recover their original files."
        alert.addButton(withTitle: "Go Back")
        alert.addButton(withTitle: "Skip and Launch")
        return alert
    }
}
