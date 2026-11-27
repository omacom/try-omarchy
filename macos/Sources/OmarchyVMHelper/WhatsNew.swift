import SwiftUI

/// What changed in the last release with news, shown once when the launcher
/// opens after an update. A fixes-only release leaves this unchanged, so it
/// shows nothing. An item that is a setting carries its switch, so people can
/// try it from there. See docs/releasing.md.
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

    static let version = AppReleaseVersion("1.5.0")!
    static let releaseNotesURL = AppRelease.releasesURL.appendingPathComponent("tag/v1.5.0")

    static let items: [Item] = [
        Item(
            id: "mac-keys",
            symbol: "keyboard",
            color: .blue,
            title: "Mac Keys and Shortcuts",
            detail: "Brightness, Mission Control and Spotlight stay with macOS. Choose which keys and shortcuts go to Omarchy in Startup → Keyboard."
        ),
        Item(
            id: "release-keyboard",
            symbol: "command",
            color: .indigo,
            title: "Back to the Mac",
            detail: "Press Control–Option–G to give the keyboard back to macOS, so Command–Tab works again, even in full screen."
        ),
        Item(
            id: "stay-awake",
            symbol: "cup.and.saucer.fill",
            color: .orange,
            title: "Stay Awake",
            detail: "Turning on Omarchy’s Stay Awake keeps the Mac’s display awake too."
        ),
        Item(
            id: "fixes",
            symbol: "wrench.and.screwdriver.fill",
            color: .gray,
            title: "Fixes",
            detail: "The desktop keeps drawing after Omarchy updates Mesa, and many other relevant fixes. For more information, check the release notes."
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
