import AppKit
import ServiceManagement

@MainActor
enum NetworkService {
    static let service = SMAppService.daemon(plistName: "dev.tryomarchy.network.plist")

    static var statusText: String {
        switch service.status {
        case .enabled: return "Networking helper approved"
        case .requiresApproval: return "Networking helper needs approval in System Settings"
        case .notRegistered: return "One-time networking helper setup required"
        case .notFound: return "Networking helper has not been registered with macOS"
        @unknown default: return "Networking helper status is unavailable"
        }
    }

    static func prepare() throws {
        if service.status == .notRegistered || service.status == .notFound {
            let plist = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/dev.tryomarchy.network.plist")
            guard FileManager.default.fileExists(atPath: plist.path) else {
                throw HelperError.io("Networking helper is missing from this app.")
            }
            do { try service.register() } catch {
                if service.status != .requiresApproval && service.status != .enabled {
                    let detail = error as NSError
                    throw HelperError.io("macOS could not register the networking helper (\(detail.domain), \(detail.code)): \(detail.localizedDescription)")
                }
            }
        }
        guard service.status == .enabled else {
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                throw HelperError.io("Approve Try Omarchy’s networking helper in System Settings → General → Login Items & Extensions, then launch again. This approval is needed once, not on every launch.")
            }
            throw HelperError.io(statusText)
        }
    }

    static func verifyConnection() throws {
        guard let resources = Bundle.main.resourceURL else { throw HelperError.io("Networking helper is missing from this app.") }
        let process = Process()
        process.executableURL = resources.appendingPathComponent("network/omarchy-network-client")
        process.arguments = ["check", resources.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "Networking helper did not respond."
            throw HelperError.io(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func remove() async throws {
        if service.status != .notRegistered && service.status != .notFound { try await service.unregister() }
    }

    static func repair() async throws {
        try await repair(isEnabled: service.status == .enabled,
                         prepare: prepare, verify: verifyConnection, remove: remove)
    }

    static func repair(isEnabled: Bool, prepare: () throws -> Void,
                       verify: () throws -> Void, remove: () async throws -> Void) async throws {
        if isEnabled {
            do {
                try verify()
                return
            } catch {
                try await remove()
            }
        }
        try prepare()
        try verify()
    }
}
