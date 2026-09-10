import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Automatic startup")
struct StartupPreferenceStoreTests {
    @Test("Automatic startup is opt-in and the choice persists")
    func savesChoice() throws {
        let suiteName = "StartupPreferenceStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = StartupPreferenceStore(defaults: defaults)
        #expect(!store.load())

        store.save(true)
        #expect(StartupPreferenceStore(defaults: defaults).load())
        store.save(false)
        #expect(!StartupPreferenceStore(defaults: defaults).load())
    }

    @Test("Only an enabled preference without Option held skips the menu",
          arguments: [false, true], [false, true])
    func respectsPreferenceAndOverride(isEnabled: Bool, optionKeyHeld: Bool) {
        #expect(StartupPolicy.shouldStartAutomatically(
            isEnabled: isEnabled,
            optionKeyHeld: optionKeyHeld,
            initialArguments: []
        ) == (isEnabled && !optionKeyHeld))
    }

    @Test("Explicit resets always reach the confirmation menu",
          arguments: ["--reset-storage", "--reset-storage-only"])
    func resetAlwaysShowsMenu(argument: String) {
        #expect(!StartupPolicy.shouldStartAutomatically(
            isEnabled: true,
            optionKeyHeld: false,
            initialArguments: [argument, "/guest"]
        ))
    }

    @Test("Ephemeral and custom guest launches honor automatic startup",
          arguments: [["--ephemeral"], ["/guest"]])
    func otherLaunchModes(arguments: [String]) {
        #expect(StartupPolicy.shouldStartAutomatically(
            isEnabled: true,
            optionKeyHeld: false,
            initialArguments: arguments
        ))
    }
}
