import SwiftUI

/// What changed in this release, shown once when the launcher opens after an
/// update. An item that is a setting carries its switch, so people can try it
/// from there.
enum WhatsNew {
    enum Setting {
        case allDisplays
    }

    struct Item: Identifiable {
        let id: String
        let symbol: String
        let color: Color
        let title: String
        let detail: String
        var setting: Setting?
    }

    static let version = AppReleaseVersion("1.4.1")!
    static let releaseNotesURL = AppRelease.releasesURL.appendingPathComponent("tag/v1.4.0")

    static let items: [Item] = [
        Item(
            id: "all-displays",
            symbol: "display.2",
            color: .blue,
            title: "All Displays",
            detail: "Omarchy can use every display connected to your Mac, arranged as in System Settings, each at its own scale.",
            setting: .allDisplays
        ),
        Item(
            id: "boot-splash",
            symbol: "sparkles",
            color: .purple,
            title: "Boot Splash",
            detail: "Omarchy’s splash screen shows again while it starts."
        ),
        Item(
            id: "fixes",
            symbol: "wrench.and.screwdriver.fill",
            color: .gray,
            title: "Fixes",
            detail: "Omarchy updates keep the desktop working, and Shift, Ctrl and Option stay held with an external mouse."
        ),
    ]

    /// Once per version, to people who already have a VM: a new install
    /// starts with Get Started instead.
    static func isDue(seen: AppReleaseVersion?, hasExistingVM: Bool) -> Bool {
        guard hasExistingVM else { return false }
        return seen.map { version > $0 } ?? true
    }

    /// A new install has nothing to catch up on. A VM on a drive that is not
    /// connected is not a new install, so it still sees this once it is back.
    static func skipsForNewInstall(hasExistingVM: Bool, storageIsReachable: Bool) -> Bool {
        !hasExistingVM && storageIsReachable
    }

    /// A drive that was not unmounted cleanly can leave its folder behind in
    /// /Volumes, so this asks whether that folder is a volume.
    static func driveIsConnected(
        for path: String,
        isVolume: (URL) -> Bool = isMountedVolume
    ) -> Bool {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard components.count > 2, components[1] == "Volumes" else { return true }
        return isVolume(URL(fileURLWithPath: "/Volumes/\(components[2])"))
    }

    static func isMountedVolume(_ url: URL) -> Bool {
        (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isVolumeKey]).isVolume) == true
    }
}

/// The last version whose What's New the launcher showed or skipped.
struct WhatsNewPreferences {
    private let defaults: UserDefaults
    private static let seenVersionKey = "LauncherWhatsNewSeenVersion"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var seenVersion: AppReleaseVersion? {
        get { defaults.string(forKey: Self.seenVersionKey).flatMap(AppReleaseVersion.init) }
        nonmutating set { defaults.set(newValue?.description, forKey: Self.seenVersionKey) }
    }
}
