import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("What's New")
struct WhatsNewTests {
    @Test("shows once per version, and only to someone who already has a VM")
    func dueOncePerVersionAfterAnUpdate() {
        let older = AppReleaseVersion("1.4.0")!
        let newer = AppReleaseVersion("9.0.0")!

        #expect(WhatsNew.isDue(seen: nil, hasExistingVM: true))
        #expect(WhatsNew.isDue(seen: older, hasExistingVM: true))
        #expect(!WhatsNew.isDue(seen: WhatsNew.version, hasExistingVM: true))
        #expect(!WhatsNew.isDue(seen: newer, hasExistingVM: true))
        // A new install starts with Get Started instead.
        #expect(!WhatsNew.isDue(seen: nil, hasExistingVM: false))
        #expect(!WhatsNew.isDue(seen: older, hasExistingVM: false))
    }

    @Test("waits for a VM whose drive is not connected")
    func waitsForADisconnectedDrive() {
        #expect(WhatsNew.skipsForNewInstall(hasExistingVM: false, storageIsReachable: true))
        #expect(!WhatsNew.skipsForNewInstall(hasExistingVM: false, storageIsReachable: false))
        #expect(!WhatsNew.skipsForNewInstall(hasExistingVM: true, storageIsReachable: true))

        let mounted: Set = ["/Volumes/Work"]
        let isVolume = { (url: URL) in mounted.contains(url.path) }
        #expect(WhatsNew.driveIsConnected(for: "/Users/someone/Library/Application Support/Try Omarchy/VM/v1", isVolume: isVolume))
        #expect(WhatsNew.driveIsConnected(for: "/Volumes/Work/Omarchy/VM/v1", isVolume: isVolume))
        #expect(!WhatsNew.driveIsConnected(for: "/Volumes/Unplugged/Omarchy/VM/v1", isVolume: isVolume))
    }

    @Test("tells a mounted drive from a folder a drive left behind")
    func checksTheVolumeItself() throws {
        let leftover = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhatsNewTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: leftover) }

        #expect(WhatsNew.isMountedVolume(URL(fileURLWithPath: "/")))
        #expect(!WhatsNew.isMountedVolume(leftover))
        #expect(!WhatsNew.isMountedVolume(leftover.appendingPathComponent("missing")))
    }

    @Test("remembers the version it showed")
    func remembersTheSeenVersion() throws {
        let suite = "WhatsNewTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = WhatsNewPreferences(defaults: defaults)

        #expect(preferences.seenVersion == nil)
        preferences.seenVersion = WhatsNew.version
        #expect(WhatsNewPreferences(defaults: defaults).seenVersion == WhatsNew.version)
        defaults.set("not a version", forKey: "LauncherWhatsNewSeenVersion")
        #expect(preferences.seenVersion == nil)
    }

    @Test("names this release, and links to its notes")
    func describesThisRelease() {
        #expect(WhatsNew.releaseNotesURL.absoluteString.hasSuffix("/tag/v1.4.0"))
        #expect(WhatsNew.items.contains { $0.setting == .allDisplays })
        #expect(Set(WhatsNew.items.map(\.id)).count == WhatsNew.items.count)
    }
}
