import Foundation

/// The guest locales try-omarchy seeds at first boot (try-omarchy-locale).
enum GuestLocaleCatalog {
    /// Use the primary macOS language, not its region or a secondary preferred
    /// language. Only return locales the launcher accepts.
    static func initialLocale(preferredLanguages: [String]) -> String {
        let language = Locale.Language(identifier: preferredLanguages.first ?? "en")
        if language.languageCode?.identifier == "ko" { return "ko_KR.UTF-8" }
        if language.languageCode?.identifier == "ja" { return "ja_JP.UTF-8" }
        guard language.languageCode?.identifier == "zh" else { return "en_US.UTF-8" }
        return language.script?.identifier == "Hant" ? "zh_TW.UTF-8" : "zh_CN.UTF-8"
    }
}

struct LanguageLaunchConfiguration: Equatable {
    static let environmentKey = "OMARCHY_QEMU_GPU_LOCALE"
    /// The primary Mac language. It never changes the guest's LANG.
    static let macLanguageKey = "OMARCHY_QEMU_GPU_MAC_LANGUAGE"

    let environment: [String: String]

    static func make(
        baseEnvironment: [String: String],
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> Self {
        var environment = baseEnvironment
        environment.removeValue(forKey: environmentKey)
        environment.removeValue(forKey: macLanguageKey)
        if let code = Locale.Language(identifier: preferredLanguages.first ?? "en").languageCode?.identifier,
           (2...3).contains(code.count), code.allSatisfy({ ("a"..."z").contains($0) }) {
            environment[macLanguageKey] = code
        }
        environment[environmentKey] = GuestLocaleCatalog.initialLocale(preferredLanguages: preferredLanguages)
        return Self(environment: environment)
    }
}
