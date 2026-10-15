import Testing
@testable import OmarchyVMHelper

@Suite("Initial guest language")
struct LanguageLaunchConfigurationTests {
    @Test("the primary Mac language chooses a generated locale", arguments: [
        (["en-US"], "en_US.UTF-8"),
        (["en-TW", "zh-Hant"], "en_US.UTF-8"),
        (["en-KR", "ko"], "en_US.UTF-8"),
        (["zh-Hant"], "zh_TW.UTF-8"),
        (["zh-Hant-US"], "zh_TW.UTF-8"),
        (["zh-TW"], "zh_TW.UTF-8"),
        (["zh-HK"], "zh_TW.UTF-8"),
        (["zh-Hans"], "zh_CN.UTF-8"),
        (["zh-CN"], "zh_CN.UTF-8"),
        (["zh-SG"], "zh_CN.UTF-8"),
        (["en-US", "ja-JP"], "en_US.UTF-8"),
        ([], "en_US.UTF-8"),
    ])
    func hostLanguage(languages: [String], expected: String) {
        for version in [2, 3, 4] {
            let commandLine = "root=/dev/vda rw tryomarchy.locale_support=\(version)\n"
            let configuration = LanguageLaunchConfiguration.make(
                baseEnvironment: [LanguageLaunchConfiguration.environmentKey: "untrusted", "PATH": "/usr/bin"],
                preferredLanguages: languages,
                supportsSelection: GuestLocaleCatalog.supportsSelection(kernelCommandLine: commandLine),
                supportsKorean: GuestLocaleCatalog.supportsSelection(kernelCommandLine: commandLine, requiresKorean: true),
                supportsJapanese: GuestLocaleCatalog.supportsSelection(kernelCommandLine: commandLine, requiresJapanese: true)
            )
            #expect(configuration.environment[LanguageLaunchConfiguration.environmentKey] == expected)
            #expect(configuration.environment["PATH"] == "/usr/bin")
        }
    }

    @Test("Korean requires a guest that generates its locale", arguments: ["ko", "ko-KR", "ko-Kore-KR"])
    func koreanLanguage(language: String) {
        for (version, expected) in [(2, "en_US.UTF-8"), (3, "ko_KR.UTF-8"), (4, "ko_KR.UTF-8")] {
            let commandLine = "root=/dev/vda rw tryomarchy.locale_support=\(version)\n"
            let configuration = LanguageLaunchConfiguration.make(
                baseEnvironment: [LanguageLaunchConfiguration.environmentKey: "untrusted"],
                preferredLanguages: [language],
                supportsSelection: GuestLocaleCatalog.supportsSelection(kernelCommandLine: commandLine),
                supportsKorean: GuestLocaleCatalog.supportsSelection(kernelCommandLine: commandLine, requiresKorean: true),
                supportsJapanese: GuestLocaleCatalog.supportsSelection(kernelCommandLine: commandLine, requiresJapanese: true)
            )
            #expect(configuration.environment[LanguageLaunchConfiguration.environmentKey] == expected)
        }
    }

    @Test("Japanese requires a guest that generates its locale", arguments: ["ja", "ja-JP", "ja-Jpan-JP"])
    func japaneseLanguage(language: String) {
        for (version, expected) in [(2, "en_US.UTF-8"), (3, "en_US.UTF-8"), (4, "ja_JP.UTF-8")] {
            let commandLine = "root=/dev/vda rw tryomarchy.locale_support=\(version)\n"
            let configuration = LanguageLaunchConfiguration.make(
                baseEnvironment: [LanguageLaunchConfiguration.environmentKey: "untrusted"],
                preferredLanguages: [language],
                supportsSelection: GuestLocaleCatalog.supportsSelection(kernelCommandLine: commandLine),
                supportsKorean: GuestLocaleCatalog.supportsSelection(kernelCommandLine: commandLine, requiresKorean: true),
                supportsJapanese: GuestLocaleCatalog.supportsSelection(kernelCommandLine: commandLine, requiresJapanese: true)
            )
            #expect(configuration.environment[LanguageLaunchConfiguration.environmentKey] == expected)
        }
    }

    @Test("the primary Mac language is passed for repairs, even when the locale is not")
    func macLanguage() {
        for (languages, version, expected) in [
            (["ja-JP"], 2, "ja"), (["ja"], 4, "ja"), (["en-US", "ja-JP"], 3, "en"), (["zh-Hant"], 0, "zh"),
        ] {
            let commandLine = "root=/dev/vda rw tryomarchy.locale_support=\(version)\n"
            let configuration = LanguageLaunchConfiguration.make(
                baseEnvironment: [LanguageLaunchConfiguration.macLanguageKey: "untrusted"],
                preferredLanguages: languages,
                supportsSelection: GuestLocaleCatalog.supportsSelection(kernelCommandLine: commandLine),
                supportsJapanese: GuestLocaleCatalog.supportsSelection(kernelCommandLine: commandLine, requiresJapanese: true)
            )
            #expect(configuration.environment[LanguageLaunchConfiguration.macLanguageKey] == expected)
        }
    }

    @Test("older saved guests cannot receive an inherited or host locale", arguments: [
        "", "tryomarchy.locale_support=1", "tryomarchy.locale_support=20", "tryomarchy.locale_support=30", "tryomarchy.locale_support=40",
    ])
    func legacyGuest(commandLine: String) {
        for language in ["zh-Hant", "ko", "ko-KR", "ko-Kore-KR", "ja", "ja-JP"] {
            let configuration = LanguageLaunchConfiguration.make(
                baseEnvironment: [LanguageLaunchConfiguration.environmentKey: "ko_KR.UTF-8"],
                preferredLanguages: [language],
                supportsSelection: GuestLocaleCatalog.supportsSelection(kernelCommandLine: commandLine),
                supportsKorean: GuestLocaleCatalog.supportsSelection(kernelCommandLine: commandLine, requiresKorean: true),
                supportsJapanese: GuestLocaleCatalog.supportsSelection(kernelCommandLine: commandLine, requiresJapanese: true)
            )
            #expect(configuration.environment[LanguageLaunchConfiguration.environmentKey] == nil)
        }
    }
}
