import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Guest locale catalog")
struct GuestLocaleCatalogTests {
    @Test("only the audited Traditional Chinese locale is recognized")
    func recognizesOnlySupportedTokens() {
        #expect(GuestLocaleCatalog.locale(forToken: "zh_TW.UTF-8") == GuestLocaleCatalog.traditionalChinese)
        #expect(GuestLocaleCatalog.locale(forToken: "en_US.UTF-8") == nil)
        #expect(GuestLocaleCatalog.locale(forToken: "zh_CN.UTF-8") == nil)
        #expect(GuestLocaleCatalog.locale(forToken: "") == nil)
        #expect(GuestLocaleCatalog.locale(forToken: "zh_TW.UTF-8; rm -rf /") == nil)
    }
}

@Suite("Language preferences")
struct LanguagePreferenceStoreTests {
    @Test("defaults to the guest's own default with no stored preference")
    func defaultsToSystemDefault() {
        let fixture = DefaultsFixture()
        #expect(fixture.store.load() == .systemDefault)
        #expect(fixture.store.load().localeToken == nil)
    }

    @Test("a chosen locale persists")
    func savesChoice() {
        let fixture = DefaultsFixture()
        fixture.store.save(LanguagePreference(localeToken: GuestLocaleCatalog.traditionalChinese.localeToken))

        let reopened = LanguagePreferenceStore(defaults: fixture.defaults)
        #expect(reopened.load().localeToken == GuestLocaleCatalog.traditionalChinese.localeToken)
    }

    @Test("switching back to the default clears the stored locale")
    func clearsChoice() {
        let fixture = DefaultsFixture()
        fixture.store.save(LanguagePreference(localeToken: GuestLocaleCatalog.traditionalChinese.localeToken))
        fixture.store.save(.systemDefault)

        #expect(fixture.store.load() == .systemDefault)
    }

    @Test("junk, future-schema, and no-longer-supported tokens fail closed to the default")
    func invalidPreferencesUseDefault() throws {
        let fixture = DefaultsFixture()
        fixture.defaults.set(Data("junk".utf8), forKey: LanguagePreferenceStore.key)
        #expect(fixture.store.load() == .systemDefault)

        let future = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": LanguagePreferenceStore.schemaVersion + 1,
            "localeToken": GuestLocaleCatalog.traditionalChinese.localeToken,
        ])
        fixture.defaults.set(future, forKey: LanguagePreferenceStore.key)
        #expect(fixture.store.load() == .systemDefault)

        let unsupported = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": LanguagePreferenceStore.schemaVersion,
            "localeToken": "fr_FR.UTF-8",
        ])
        fixture.defaults.set(unsupported, forKey: LanguagePreferenceStore.key)
        #expect(fixture.store.load() == .systemDefault)
    }

    private final class DefaultsFixture {
        let suiteName = "LanguagePreferenceStoreTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let store: LanguagePreferenceStore

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            store = LanguagePreferenceStore(defaults: defaults)
        }

        deinit {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

@Suite("Language launch configuration")
struct LanguageLaunchConfigurationTests {
    @Test("no preference emits no token and strips any inherited value")
    func defaultEmitsNothing() {
        let inherited = [
            "KEEP_ME": "yes",
            LanguageLaunchConfiguration.environmentKey: "zh_TW.UTF-8",
        ]

        let configuration = LanguageLaunchConfiguration.make(
            baseEnvironment: inherited,
            preference: .systemDefault
        )
        #expect(configuration.environment["KEEP_ME"] == "yes")
        #expect(configuration.environment[LanguageLaunchConfiguration.environmentKey] == nil)
    }

    @Test("a supported locale publishes its token")
    func supportedLocalePublishesToken() {
        let configuration = LanguageLaunchConfiguration.make(
            baseEnvironment: ["KEEP_ME": "yes"],
            preference: LanguagePreference(localeToken: GuestLocaleCatalog.traditionalChinese.localeToken)
        )
        #expect(configuration.environment["KEEP_ME"] == "yes")
        #expect(configuration.environment[LanguageLaunchConfiguration.environmentKey] == "zh_TW.UTF-8")
    }

    @Test("a token outside the allowlist is dropped rather than passed through")
    func unsupportedTokenIsDropped() {
        let configuration = LanguageLaunchConfiguration.make(
            baseEnvironment: [:],
            preference: LanguagePreference(localeToken: "fr_FR.UTF-8")
        )
        #expect(configuration.environment[LanguageLaunchConfiguration.environmentKey] == nil)
    }
}

@Suite("Language menu state")
struct LanguageMenuStateTests {
    @Test("no preference resolves to the system default")
    func systemDefaultResolves() {
        #expect(LanguageMenuState.make(preference: .systemDefault) == .systemDefault)
    }

    @Test("a supported preference resolves to its catalog locale")
    func supportedPreferenceResolves() {
        let state = LanguageMenuState.make(
            preference: LanguagePreference(localeToken: GuestLocaleCatalog.traditionalChinese.localeToken)
        )
        #expect(state.selectedLocale == GuestLocaleCatalog.traditionalChinese)
    }

    @Test("an unsupported preference fails closed to the system default")
    func unsupportedPreferenceFailsClosed() {
        let state = LanguageMenuState.make(preference: LanguagePreference(localeToken: "ja_JP.UTF-8"))
        #expect(state == .systemDefault)
    }
}
