import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Keyboard routing preferences")
struct KeyboardRoutingPreferenceStoreTests {
    @Test("Every dedicated key stays with macOS until the user changes it")
    func defaultsToMacOS() {
        let fixture = DefaultsFixture()
        let loaded = fixture.store.load()
        #expect(loaded == .defaults)
        #expect(loaded.brightness == .macOS)
        #expect(loaded.missionControl == .macOS)
        #expect(loaded.spotlight == .macOS)
        #expect(loaded.dictation == .macOS)
        #expect(loaded.doNotDisturb == .macOS)
    }

    @Test("A payload saved before Dictation and Do Not Disturb existed loads them as macOS")
    func olderPayloadDefaultsNewFieldsToMacOS() throws {
        let fixture = DefaultsFixture()
        let older = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": KeyboardRoutingPreferenceStore.schemaVersion,
            "brightness": "omarchy", "missionControl": "omarchy", "spotlight": "omarchy",
        ])
        fixture.defaults.set(older, forKey: KeyboardRoutingPreferenceStore.key)
        let loaded = fixture.store.load()
        #expect(loaded.brightness == .omarchy)
        #expect(loaded.missionControl == .omarchy)
        #expect(loaded.spotlight == .omarchy)
        #expect(loaded.dictation == .macOS)
        #expect(loaded.doNotDisturb == .macOS)
    }

    @Test("Dictation and Do Not Disturb round-trip through the store")
    func roundTripsDictationAndDoNotDisturb() {
        let fixture = DefaultsFixture()
        let choice = KeyboardRoutingPreferences(
            brightness: .macOS, missionControl: .macOS, spotlight: .macOS,
            dictation: .omarchy, doNotDisturb: .omarchy
        )
        fixture.store.save(choice)
        let loaded = KeyboardRoutingPreferenceStore(defaults: fixture.defaults).load()
        #expect(loaded == choice)
        #expect(loaded.dictation == .omarchy)
        #expect(loaded.doNotDisturb == .omarchy)
    }

    @Test("Routing choices persist")
    func savesChoices() {
        let fixture = DefaultsFixture()
        let choice = KeyboardRoutingPreferences(
            brightness: .macOS, missionControl: .omarchy, spotlight: .omarchy
        )
        fixture.store.save(choice)
        #expect(KeyboardRoutingPreferenceStore(defaults: fixture.defaults).load() == choice)
    }

    @Test("Invalid or future preferences fail safely")
    func invalidPreferencesUseDefault() throws {
        let fixture = DefaultsFixture()
        fixture.defaults.set(Data("junk".utf8), forKey: KeyboardRoutingPreferenceStore.key)
        #expect(fixture.store.load() == .defaults)

        let future = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": KeyboardRoutingPreferenceStore.schemaVersion + 1,
            "brightness": "omarchy", "missionControl": "omarchy", "spotlight": "omarchy",
        ])
        fixture.defaults.set(future, forKey: KeyboardRoutingPreferenceStore.key)
        #expect(fixture.store.load() == .defaults)
    }

    @Test("Host keycodes are the sorted keycodes of rows left with macOS")
    func hostKeycodes() {
        #expect(KeyboardRoutingPreferences.defaults.hostKeycodes == [131, 144, 145, 160, 176, 177, 178])
        #expect(KeyboardRoutingPreferences(
            brightness: .omarchy, missionControl: .omarchy, spotlight: .omarchy,
            dictation: .omarchy, doNotDisturb: .omarchy
        ).hostKeycodes == [])
        #expect(KeyboardRoutingPreferences(
            brightness: .macOS, missionControl: .omarchy, spotlight: .omarchy,
            dictation: .omarchy, doNotDisturb: .omarchy
        ).hostKeycodes == [144, 145])
    }

    @Test("Media keys default to macOS and an older payload without them still loads")
    func mediaDefaultsAndMigration() throws {
        let fixture = DefaultsFixture()
        #expect(fixture.store.load().media == .macOS)

        let older = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": KeyboardRoutingPreferenceStore.schemaVersion,
            "brightness": "macOS", "missionControl": "omarchy", "spotlight": "macOS",
        ])
        fixture.defaults.set(older, forKey: KeyboardRoutingPreferenceStore.key)
        #expect(fixture.store.load() == KeyboardRoutingPreferences(
            brightness: .macOS, missionControl: .omarchy, spotlight: .macOS, media: .macOS
        ))

        let choice = KeyboardRoutingPreferences(
            brightness: .macOS, missionControl: .macOS, spotlight: .macOS, media: .omarchy
        )
        fixture.store.save(choice)
        #expect(fixture.store.load() == choice)
        #expect(choice.hostKeycodes == KeyboardRoutingPreferences.defaults.hostKeycodes)
    }

    private final class DefaultsFixture {
        let suiteName = "KeyboardRoutingPreferenceStoreTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let store: KeyboardRoutingPreferenceStore

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            store = KeyboardRoutingPreferenceStore(defaults: defaults)
        }

        deinit {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

@Suite("Keyboard routing launch configuration")
struct KeyboardRoutingLaunchConfigurationTests {
    @Test("Publishes host keycodes and replaces inherited values")
    func publishesHostKeys() {
        let inherited = [
            "KEEP_ME": "yes",
            KeyboardRoutingLaunchConfiguration.hostKeysEnvironmentKey: "999",
        ]
        let defaults = KeyboardRoutingLaunchConfiguration.make(
            baseEnvironment: inherited, preferences: .defaults
        )
        #expect(defaults.environment["KEEP_ME"] == "yes")
        #expect(defaults.environment[KeyboardRoutingLaunchConfiguration.hostKeysEnvironmentKey] == "131,144,145,160,176,177,178")

        let none = KeyboardRoutingLaunchConfiguration.make(
            baseEnvironment: inherited,
            preferences: KeyboardRoutingPreferences(
                brightness: .omarchy, missionControl: .omarchy, spotlight: .omarchy,
                dictation: .omarchy, doNotDisturb: .omarchy
            )
        )
        #expect(none.environment[KeyboardRoutingLaunchConfiguration.hostKeysEnvironmentKey] == "")
    }

    @Test("Publishes the media-key choice and replaces inherited values")
    func publishesMediaKeys() {
        let inherited = [KeyboardRoutingLaunchConfiguration.mediaKeysEnvironmentKey: "9"]
        let defaults = KeyboardRoutingLaunchConfiguration.make(baseEnvironment: inherited, preferences: .defaults)
        #expect(defaults.environment[KeyboardRoutingLaunchConfiguration.mediaKeysEnvironmentKey] == "0")
        var omarchy = KeyboardRoutingPreferences.defaults
        omarchy.media = .omarchy
        let sent = KeyboardRoutingLaunchConfiguration.make(baseEnvironment: inherited, preferences: omarchy)
        #expect(sent.environment[KeyboardRoutingLaunchConfiguration.mediaKeysEnvironmentKey] == "1")
        #expect(sent.environment[KeyboardRoutingLaunchConfiguration.hostKeysEnvironmentKey] == "131,144,145,160,176,177,178")
    }
}
