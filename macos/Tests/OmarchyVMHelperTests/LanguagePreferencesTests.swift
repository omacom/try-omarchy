import Testing
@testable import OmarchyVMHelper

@Suite("Initial guest language")
struct LanguageLaunchConfigurationTests {
    @Test("the primary Mac language chooses a locale the guest seeds", arguments: [
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
        (["ko"], "ko_KR.UTF-8"),
        (["ko-Kore-KR"], "ko_KR.UTF-8"),
        (["ja-JP"], "ja_JP.UTF-8"),
        (["ja-Jpan-JP"], "ja_JP.UTF-8"),
        (["en-US", "ja-JP"], "en_US.UTF-8"),
        (["fr-FR"], "en_US.UTF-8"),
        ([], "en_US.UTF-8"),
    ])
    func hostLanguage(languages: [String], expected: String) {
        let configuration = LanguageLaunchConfiguration.make(
            baseEnvironment: [LanguageLaunchConfiguration.environmentKey: "untrusted", "PATH": "/usr/bin"],
            preferredLanguages: languages
        )
        #expect(configuration.environment[LanguageLaunchConfiguration.environmentKey] == expected)
        #expect(configuration.environment["PATH"] == "/usr/bin")
    }

    @Test("the primary Mac language is passed on its own")
    func macLanguage() {
        for (languages, expected) in [(["ja-JP"], "ja"), (["en-US", "ja-JP"], "en"), (["zh-Hant"], "zh")] {
            let configuration = LanguageLaunchConfiguration.make(
                baseEnvironment: [LanguageLaunchConfiguration.macLanguageKey: "untrusted"],
                preferredLanguages: languages
            )
            #expect(configuration.environment[LanguageLaunchConfiguration.macLanguageKey] == expected)
        }
    }
}
