import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("HDR preferences")
struct HDRPreferenceStoreTests {
    @Test("HDR is off by default")
    func defaultsToOff() {
        let fixture = DefaultsFixture()

        #expect(fixture.store.load() == .defaults)
        #expect(!fixture.store.load().isEnabled)
    }

    @Test("HDR choice persists")
    func savesChoice() {
        let fixture = DefaultsFixture()
        fixture.store.save(HDRPreferences(isEnabled: true))

        let reopened = HDRPreferenceStore(defaults: fixture.defaults)
        #expect(reopened.load() == HDRPreferences(isEnabled: true))
    }

    @Test("Invalid or future preferences fail safely")
    func invalidPreferencesUseDefault() throws {
        let fixture = DefaultsFixture()
        fixture.defaults.set(Data("junk".utf8), forKey: HDRPreferenceStore.key)
        #expect(fixture.store.load() == .defaults)

        let future = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": HDRPreferenceStore.schemaVersion + 1,
            "isEnabled": true,
        ])
        fixture.defaults.set(future, forKey: HDRPreferenceStore.key)
        #expect(fixture.store.load() == .defaults)
    }

    private final class DefaultsFixture {
        let suiteName = "HDRPreferenceStoreTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let store: HDRPreferenceStore

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            store = HDRPreferenceStore(defaults: defaults)
        }

        deinit {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

@Suite("HDR launch configuration")
struct HDRLaunchConfigurationTests {
    @Test("Publishes the saved choice, replaces inherited HDR, and retains unrelated environment")
    func publishesChoice() {
        let inherited = [
            "KEEP_ME": "yes",
            HDRLaunchConfiguration.environmentKey: "invalid",
        ]

        let enabled = HDRLaunchConfiguration.make(
            baseEnvironment: inherited,
            preferences: HDRPreferences(isEnabled: true)
        )
        #expect(enabled.environment["KEEP_ME"] == "yes")
        #expect(enabled.environment[HDRLaunchConfiguration.environmentKey] == "1")

        let disabled = HDRLaunchConfiguration.make(
            baseEnvironment: inherited,
            preferences: HDRPreferences(isEnabled: false)
        )
        #expect(disabled.environment["KEEP_ME"] == "yes")
        #expect(disabled.environment[HDRLaunchConfiguration.environmentKey] == "0")
    }
}
