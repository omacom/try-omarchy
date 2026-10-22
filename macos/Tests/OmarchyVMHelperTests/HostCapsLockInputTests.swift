import Testing
@testable import OmarchyVMHelper

@Suite("Host Caps Lock input")
struct HostCapsLockInputTests {
    static let abc = HostCapsLockInput.Source(id: "com.apple.keylayout.ABC", isInputMode: false, isASCIICapable: true)
    static let korean = HostCapsLockInput.Source(id: "com.apple.inputmethod.Korean.2SetKorean", isInputMode: true, isASCIICapable: false)
    static let pinyin = HostCapsLockInput.Source(id: "com.apple.inputmethod.SCIM.ITABC", isInputMode: true, isASCIICapable: false)
    static let japanese = HostCapsLockInput.Source(id: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese", isInputMode: true, isASCIICapable: false)

    @Test("Korean as the only input method keeps the 한/영 repeat")
    func koreanInputSource() {
        #expect(HostCapsLockInput.mode(enabledInputSources: [Self.abc, Self.korean]) == "hangul")
        #expect(HostCapsLockInput.mode(enabledInputSources: [
            Self.korean,
            .init(id: "com.apple.inputmethod.Korean.3SetKorean", isInputMode: true, isASCIICapable: false),
        ]) == "hangul")
    }

    @Test("other input methods follow the Mac without the repeat")
    func otherInputMethods() {
        #expect(HostCapsLockInput.mode(enabledInputSources: [Self.abc, Self.pinyin]) == "input-method")
        #expect(HostCapsLockInput.mode(enabledInputSources: [Self.abc, Self.japanese]) == "input-method")
        #expect(HostCapsLockInput.mode(enabledInputSources: [Self.korean, Self.pinyin]) == "input-method")
    }

    @Test("keyboard layouts and Latin input modes keep Caps Lock")
    func latinInputSources() {
        #expect(HostCapsLockInput.mode(enabledInputSources: []) == "")
        #expect(HostCapsLockInput.mode(enabledInputSources: [
            Self.abc,
            .init(id: "com.apple.keylayout.Russian", isInputMode: false, isASCIICapable: false),
            .init(id: "com.apple.inputmethod.Kotoeri.RomajiTyping.Roman", isInputMode: true, isASCIICapable: true),
            .init(id: "com.apple.inputmethod.Korean", isInputMode: false, isASCIICapable: false),
        ]) == "")
    }
}
