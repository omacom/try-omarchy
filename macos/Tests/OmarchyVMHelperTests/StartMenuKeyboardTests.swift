import AppKit
import Testing
@testable import OmarchyVMHelper

@Suite("Start menu keyboard routing", .serialized)
@MainActor
struct StartMenuKeyboardTests {
    @Test("Keyboard detail names which keys stay with macOS")
    func detail() {
        #expect(StartMenuPresentation.keyboardRouting(.defaults)
            == "Brightness, Mission Control, Spotlight, Dictation, Do Not Disturb stay with macOS.")
        #expect(StartMenuPresentation.keyboardRouting(KeyboardRoutingPreferences(
            brightness: .omarchy, missionControl: .omarchy, spotlight: .omarchy,
            dictation: .omarchy, doNotDisturb: .omarchy
        )) == "Brightness, Mission Control, Spotlight, Dictation, Do Not Disturb go to Omarchy.")
        #expect(StartMenuPresentation.keyboardRouting(KeyboardRoutingPreferences(
            brightness: .macOS, missionControl: .omarchy, spotlight: .omarchy,
            dictation: .omarchy, doNotDisturb: .omarchy
        )) == "Brightness stays with macOS · Mission Control, Spotlight, Dictation, Do Not Disturb go to Omarchy.")
    }

    @Test("Configure opens the keyboard sheet and Save stores the choice")
    func configureSaves() throws {
        _ = NSApplication.shared
        var stored = KeyboardRoutingPreferences.defaults
        let menu = StartMenuWindow(
            accessibilityStatus: { true },
            microphoneStatus: { .authorized },
            cameraStatus: { .authorized },
            requestAccessibility: {},
            requestMicrophone: { completion in completion(true) },
            requestCamera: { completion in completion(true) },
            canResetStorage: true,
            storageLocation: { StorageLocationMenuState.defaultLocation.displayPath },
            storageLocationURL: { nil },
            storageSpaceEstimate: { nil },
            storageLocationStatus: { .defaultLocation },
            validateStorageLocation: { _ in nil },
            chooseStorageLocation: { _ in nil },
            useDefaultStorageLocation: {},
            resetStorage: {},
            sharedFolderStatus: { .disabled },
            chooseSharedFolder: { _ in nil },
            setSharedFolderEnabled: { _ in },
            portForwardingStatus: { [] },
            keyboardRouting: { stored },
            saveKeyboardRouting: { stored = $0 },
            launch: {}
        )
        defer { menu.dismiss() }
        menu.prepareForPresentation(visibleFrame: nil)
        let content = try #require(menu.window.contentView)
        let configure = try #require(
            descendant(withIdentifier: "permission-action-keyboard", in: content) as? NSButton
        )
        configure.performClick(nil)
        let editor = try #require(menu.keyboardRoutingEditor)
        let editorContent = try #require(editor.window.contentView)
        let spotlight = try #require(
            descendant(withIdentifier: "keyboard-routing-spotlight", in: editorContent) as? NSPopUpButton
        )
        spotlight.selectItem(withTag: 1)
        let save = try #require(
            descendant(withIdentifier: "keyboard-routing-save", in: editorContent) as? NSButton
        )
        save.performClick(nil)
        #expect(stored.spotlight == .omarchy)
        #expect(menu.keyboardRoutingEditor == nil)
    }

    private func descendant(withIdentifier identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier { return view }
        for child in view.subviews {
            if let found = descendant(withIdentifier: identifier, in: child) { return found }
        }
        return nil
    }
}
