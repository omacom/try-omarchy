import Foundation

/// Sparkle installs signed app updates (docs/app-updates.md). It stays off
/// until the bundle names both a feed and the key that signs its updates, so
/// development builds and kits keep only the GitHub release check.
enum AppUpdater {
    static let configurationKeys = ["SUFeedURL", "SUPublicEDKey"]

    static func isConfigured(_ info: [String: Any]) -> Bool {
        configurationKeys.allSatisfy {
            (info[$0] as? String).map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? false
        }
    }
}
