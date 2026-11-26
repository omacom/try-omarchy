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

    @Test("Keyboard detail counts kept shortcuts with macOS")
    func shortcutCount() {
        var preferences = KeyboardRoutingPreferences.defaults
        preferences.shortcuts = [KeptShortcut(keyCode: 123, modifiers: .control, key: "←")]
        #expect(StartMenuPresentation.keyboardRouting(preferences)
            == "Brightness, Mission Control, Spotlight, Dictation, Do Not Disturb, Media, 1 shortcut stay with macOS.")
        preferences = KeyboardRoutingPreferences(
            brightness: .omarchy, missionControl: .omarchy, spotlight: .omarchy,
            dictation: .omarchy, doNotDisturb: .omarchy, media: .omarchy,
            shortcuts: [
                KeptShortcut(keyCode: 123, modifiers: .control, key: "←"),
                KeptShortcut(keyCode: 124, modifiers: .control, key: "→"),
            ]
        )
        #expect(StartMenuPresentation.keyboardRouting(preferences)
            == "2 shortcuts stay with macOS · Brightness, Mission Control, Spotlight, Dictation, Do Not Disturb, Media go to Omarchy.")
    }
}
