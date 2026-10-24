import Foundation
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

    @Test func checkedInInfoPlistLeavesItOff() throws {
        let plist = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../Info.plist").standardized
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil)
        #expect(!AppUpdater.isConfigured(try #require(info as? [String: Any])))
    }
}
