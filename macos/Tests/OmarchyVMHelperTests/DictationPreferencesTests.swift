import Foundation
import Testing

@testable import OmarchyVMHelper

@Suite("Dictation preferences")
struct DictationPreferencesTests {
    private final class DefaultsFixture {
        let suiteName = "DictationPreferenceStoreTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let store: DictationPreferenceStore

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            store = DictationPreferenceStore(defaults: defaults)
        }

        deinit {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    @Test("Dictation is on until the user turns it off, and the choice persists")
    func storeRoundTripsAndDefaultsOn() {
        let fixture = DefaultsFixture()
        #expect(fixture.store.load() == .defaults)
        #expect(fixture.store.load().isEnabled)

        fixture.store.save(DictationPreferences(isEnabled: false))
        #expect(DictationPreferenceStore(defaults: fixture.defaults).load().isEnabled == false)

        fixture.defaults.set(Data("junk".utf8), forKey: DictationPreferenceStore.key)
        #expect(fixture.store.load() == .defaults)
    }

    @Test("A supported Mac exports the saved choice")
    func supportedHostsExportThePreference() {
        let on = DictationLaunchConfiguration.make(
            baseEnvironment: [:], preferences: DictationPreferences(isEnabled: true), isSupported: true
        )
        #expect(on.environment[DictationLaunchConfiguration.environmentKey] == "1")
        let off = DictationLaunchConfiguration.make(
            baseEnvironment: [:], preferences: DictationPreferences(isEnabled: false), isSupported: true
        )
        #expect(off.environment["OMARCHY_QEMU_GPU_DICTATION"] == "0")
    }

    @Test("macOS 15 or a pre-26 SDK build exports 0 whatever the choice")
    func unsupportedHostsExportZero() {
        let configuration = DictationLaunchConfiguration.make(
            baseEnvironment: ["OMARCHY_QEMU_GPU_DICTATION": "1", "OTHER": "kept"],
            preferences: DictationPreferences(isEnabled: true),
            isSupported: false
        )
        #expect(configuration.environment["OMARCHY_QEMU_GPU_DICTATION"] == "0")
        #expect(configuration.environment["OTHER"] == "kept")
    }

    @Test("The Dictation row describes what the setting does")
    func dictationCopy() {
        #expect(StartMenuPresentation.dictationDetail(isEnabled: true)
            == "Apple speech recognition for Omarchy’s dictation, using the Mac microphone.")
        #expect(StartMenuPresentation.dictationDetail(isEnabled: false)
            == "Omarchy’s dictation can’t use Apple speech recognition.")
    }
}
