import AppKit
import Testing
@testable import OmarchyVMHelper

@Suite("Mac app updater configuration")
struct AppUpdaterTests {
    @Test func staysOffWithoutBothFeedAndKey() {
        let feed = "https://github.com/omacom/try-omarchy/releases/latest/download/appcast.xml"
        #expect(!AppUpdater.isConfigured([:]))
        #expect(!AppUpdater.isConfigured(["SUFeedURL": feed]))
        #expect(!AppUpdater.isConfigured(["SUPublicEDKey": "key"]))
        #expect(!AppUpdater.isConfigured(["SUFeedURL": feed, "SUPublicEDKey": " "]))
        #expect(AppUpdater.isConfigured(["SUFeedURL": feed, "SUPublicEDKey": "key"]))
    }

    @Test func infoPlistNamesTheReleaseFeedAndAKeyOrNeither() throws {
        let plist = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../Info.plist").standardized
        let info = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
        )
        if AppUpdater.isConfigured(info) {
            #expect(info["SUFeedURL"] as? String == "https://github.com/omacom/try-omarchy/releases/latest/download/appcast.xml")
            let key = try #require(info["SUPublicEDKey"] as? String)
            #expect(Data(base64Encoded: key)?.count == 32)
        } else {
            #expect(AppUpdater.configurationKeys.allSatisfy { info[$0] == nil })
        }
        // The launcher asks and schedules; Sparkle only checks the archive before opening it.
        #expect(info["SUEnableAutomaticChecks"] as? Bool == false)
        #expect(info["SUAllowsAutomaticUpdates"] as? Bool == false)
        #expect(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
    }

    @Test @MainActor func onlyReleasesUpdateThemselves() {
        let configured = ["SUFeedURL": "https://example.invalid/appcast.xml", "SUPublicEDKey": "key",
                          "CFBundleShortVersionString": "1.5.0"]
        #expect(AppUpdater(info: configured) == nil)
        #expect(AppUpdater(info: configured.merging(["TryOmarchyBuildDescribe": "v1.5.0-3-gabc"]) { $1 }) == nil)
        #expect(AppUpdater(info: ["CFBundleShortVersionString": "1.5.0", "TryOmarchyBuildDescribe": "v1.5.0"]) == nil)
    }

    @Test @MainActor func feedVersionsAreReleases() throws {
        #expect(try AppUpdater.release("1.5.0").url.absoluteString
            == "https://github.com/omacom/try-omarchy/releases/tag/v1.5.0")
        for invalid in ["", "1.5", "v1.5.0", "1.5.0/../../evil"] {
            #expect(throws: AppReleaseError.self) { try AppUpdater.release(invalid) }
        }
    }

    @Test func updatesNeverInterruptOmarchy() {
        func step(running: Bool = false, reachedStart: Bool = false, stopping: Bool = false,
                  downloading: Bool = false, changingStorage: Bool = false,
                  otherInstances: Bool = false) -> AppUpdateStep {
            .next(sessionRunning: running, reachedStart: reachedStart, stopping: stopping,
                  downloading: downloading, changingStorage: changingStorage, otherInstances: otherInstances)
        }
        #expect(step() == .install)
        // A finished session keeps reachedStart until the next launch.
        #expect(step(reachedStart: true) == .install)
        #expect(step(running: true, reachedStart: true) == .shutDownFirst)
        #expect(step(running: true) == .wait)
        #expect(step(running: true, reachedStart: true, stopping: true) == .wait)
        #expect(step(downloading: true) == .wait)
        #expect(step(changingStorage: true) == .wait)
        #expect(step(otherInstances: true) == .wait)
        #expect(step(running: true, reachedStart: true, changingStorage: true) == .wait)
    }

    @Test @MainActor func promptsSayWhatUpdatingDoes() throws {
        let release = AppRelease(version: try #require(AppReleaseVersion("1.5.0")))
        func buttons(_ alert: NSAlert) -> [String] { alert.buttons.map(\.title) }
        #expect(buttons(AppReleasePrompt.alert(for: release)) == ["Download", "Skip"])
        let idle = AppReleasePrompt.alert(for: release, installsUpdates: true)
        #expect(buttons(idle) == ["Update", "Skip", "Release Notes"])
        let running = AppReleasePrompt.alert(for: release, installsUpdates: true, omarchyRuns: true)
        #expect(buttons(running) == ["Shut Down and Update", "Skip", "Release Notes"])
        #expect(running.informativeText.hasPrefix("Save your work first."))
        #expect(AppReleasePrompt.shutDownAlert().buttons.last?.title == "Cancel")
    }
}
