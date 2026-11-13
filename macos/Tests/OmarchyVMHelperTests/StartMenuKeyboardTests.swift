import Testing
@testable import OmarchyVMHelper

@Suite("Start menu keyboard routing")
struct StartMenuKeyboardTests {
    @Test("Keyboard detail names which keys stay with macOS")
    func detail() {
        #expect(StartMenuPresentation.keyboardRouting(.defaults)
            == "Brightness, Mission Control, Spotlight, Dictation, Do Not Disturb, Media stay with macOS.")
        #expect(StartMenuPresentation.keyboardRouting(KeyboardRoutingPreferences(
            brightness: .omarchy, missionControl: .omarchy, spotlight: .omarchy,
            dictation: .omarchy, doNotDisturb: .omarchy, media: .omarchy
        )) == "Brightness, Mission Control, Spotlight, Dictation, Do Not Disturb, Media go to Omarchy.")
        #expect(StartMenuPresentation.keyboardRouting(KeyboardRoutingPreferences(
            brightness: .macOS, missionControl: .omarchy, spotlight: .omarchy,
            dictation: .omarchy, doNotDisturb: .omarchy, media: .omarchy
        )) == "Brightness stays with macOS · Mission Control, Spotlight, Dictation, Do Not Disturb, Media go to Omarchy.")
    }
}
