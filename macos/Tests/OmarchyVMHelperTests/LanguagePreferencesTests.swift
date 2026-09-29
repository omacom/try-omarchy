import Testing
@testable import OmarchyVMHelper

@Suite("Initial guest language")
struct LanguageLaunchConfigurationTests {
    @Test("the primary Mac language chooses a generated locale", arguments: [
        (["en-US"], "en_US.UTF-8"),
        (["en-TW", "zh-Hant"], "en_US.UTF-8"),
        (["zh-Hant"], "zh_TW.UTF-8"),
        (["zh-Hant-US"], "zh_TW.UTF-8"),
        (["zh-TW"], "zh_TW.UTF-8"),
        (["zh-HK"], "zh_TW.UTF-8"),
        (["zh-Hans"], "zh_CN.UTF-8"),
        (["zh-CN"], "zh_CN.UTF-8"),
        (["zh-SG"], "zh_CN.UTF-8"),
        (["ja-JP", "zh-Hant"], "en_US.UTF-8"),
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

    @Test("older saved guests cannot receive an inherited or host locale")
    func legacyGuest() {
        let configuration = LanguageLaunchConfiguration.make(
            baseEnvironment: [LanguageLaunchConfiguration.environmentKey: "zh_TW.UTF-8"],
            preferredLanguages: ["zh-Hant"],
            supportsSelection: false
        )
        #expect(configuration.environment[LanguageLaunchConfiguration.environmentKey] == nil)
    }
}
