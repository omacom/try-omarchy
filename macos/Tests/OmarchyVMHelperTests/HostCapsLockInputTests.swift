import Testing
@testable import OmarchyVMHelper

@Suite("Host Caps Lock input")
struct HostCapsLockInputTests {
    @Test("an enabled Apple Korean input source makes Caps Lock the Hangul key")
    func koreanInputSource() {
        #expect(HostCapsLockInput.mode(enabledInputSourceIDs: [
            "com.apple.keylayout.ABC",
            "com.apple.inputmethod.Korean.2SetKorean",
        ]) == "hangul")
        #expect(HostCapsLockInput.mode(enabledInputSourceIDs: ["com.apple.inputmethod.Korean"]) == "hangul")
    }

    @Test("other input sources keep Caps Lock")
    func otherInputSources() {
        #expect(HostCapsLockInput.mode(enabledInputSourceIDs: []) == "")
        #expect(HostCapsLockInput.mode(enabledInputSourceIDs: [
            "com.apple.keylayout.ABC",
            "com.apple.keylayout.2SetHangul",
            "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese",
            "com.apple.inputmethod.SCIM.ITABC",
        ]) == "")
    }
}
