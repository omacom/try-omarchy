import Foundation

/// A guest locale the launcher may ask the guest to boot into.
///
/// `localeToken` becomes both the value of `tryomarchy.locale=<value>` on the
/// guest kernel command line and, once the guest writes it into
/// `/etc/locale.conf`, the session `LANG`. It is kept byte-identical to the `LANG` values
/// `configure-rootfs.sh` writes into the guest's `/etc/locale.gen`, so the
/// same string names the locale on both sides of the boundary.
struct GuestLocale: Equatable {
    let localeToken: String
    /// Shown in the start menu. English is not listed here — it is the
    /// system default and has no row entry of its own.
    let displayName: String
}

/// The guest-generated locales a user may opt into, beyond the guest's own
/// default. The guest image only ever generates the locales listed here, so
/// this is the complete allowlist: the launcher never forwards an arbitrary
/// string to the kernel command line, and `run-qemu-gpu.sh` re-checks against
/// its own copy of this same list before trusting its environment.
///
/// Adding a locale later is a data change to `supported` — the preference
/// store, launch configuration, and menu presentation all read from this
/// list rather than naming a specific locale.
enum GuestLocaleCatalog {
    static let traditionalChinese = GuestLocale(
        localeToken: "zh_TW.UTF-8",
        displayName: "Traditional Chinese (繁體中文)"
    )

    static let supported: [GuestLocale] = [traditionalChinese]

    static func locale(forToken token: String) -> GuestLocale? {
        supported.first { $0.localeToken == token }
    }
}

/// The user's chosen guest language. `nil` leaves the guest at its own
/// default — English (`en_US.UTF-8`) — so a user who never opens this
/// setting sees no behavioral change.
struct LanguagePreference: Equatable {
    var localeToken: String?

    static let systemDefault = Self(localeToken: nil)
}

struct LanguagePreferenceStore {
    static let key = "languagePreferences"
    static let schemaVersion = 1

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Unknown, malformed, future-schema, or no-longer-supported tokens fail
    /// closed to the system default rather than ever reaching the launcher
    /// unvalidated.
    func load() -> LanguagePreference {
        guard let data = defaults.data(forKey: Self.key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schemaVersion == Self.schemaVersion else {
            return .systemDefault
        }
        guard let token = payload.localeToken, GuestLocaleCatalog.locale(forToken: token) != nil else {
            return .systemDefault
        }
        return LanguagePreference(localeToken: token)
    }

    func save(_ preference: LanguagePreference) {
        let payload = Payload(schemaVersion: Self.schemaVersion, localeToken: preference.localeToken)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private struct Payload: Codable {
        let schemaVersion: Int
        let localeToken: String?
    }
}

struct LanguageLaunchConfiguration: Equatable {
    static let environmentKey = "OMARCHY_QEMU_GPU_LOCALE"

    let environment: [String: String]

    /// Publishes the validated locale to the launcher script, or removes any
    /// inherited value so an environment leak can never boot a locale the
    /// user did not pick in this app. A token outside the allowlist — which
    /// `load()` above should already prevent — is treated the same as no
    /// preference at all rather than passed through.
    static func make(
        baseEnvironment: [String: String],
        preference: LanguagePreference
    ) -> Self {
        var environment = baseEnvironment
        environment.removeValue(forKey: environmentKey)
        guard let token = preference.localeToken,
              GuestLocaleCatalog.locale(forToken: token) != nil else {
            return Self(environment: environment)
        }
        environment[environmentKey] = token
        return Self(environment: environment)
    }
}

/// What the start menu shows for the language row.
struct LanguageMenuState: Equatable {
    let selectedLocale: GuestLocale?

    static let systemDefault = Self(selectedLocale: nil)

    static func make(preference: LanguagePreference) -> Self {
        guard let token = preference.localeToken,
              let locale = GuestLocaleCatalog.locale(forToken: token) else {
            return .systemDefault
        }
        return Self(selectedLocale: locale)
    }
}
