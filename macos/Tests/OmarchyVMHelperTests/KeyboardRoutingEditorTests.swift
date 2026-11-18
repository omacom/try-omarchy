import AppKit
import Testing
@testable import OmarchyVMHelper

@Suite("Keyboard routing editor", .serialized)
@MainActor
struct KeyboardRoutingEditorTests {
    @Test("Shows the saved routes and Save publishes the draft once")
    func showsAndSaves() throws {
        _ = NSApplication.shared
        var saved: [KeyboardRoutingPreferences] = []
        var closed = 0
        let editor = KeyboardRoutingEditor(
            preferences: .defaults,
            save: { saved.append($0) },
            didClose: { closed += 1 }
        )
        let brightness: NSPopUpButton = try control("brightness", in: editor)
        let spotlight: NSPopUpButton = try control("spotlight", in: editor)
        let dictation: NSPopUpButton = try control("dictation", in: editor)
        let doNotDisturb: NSPopUpButton = try control("do-not-disturb", in: editor)
        #expect(brightness.itemTitles == ["macOS", "Omarchy"])
        #expect(brightness.selectedItem?.tag == 0)
        #expect(dictation.selectedItem?.tag == 0)
        #expect(doNotDisturb.selectedItem?.tag == 0)
        spotlight.selectItem(withTag: 1)
        dictation.selectItem(withTag: 1)
        doNotDisturb.selectItem(withTag: 1)
        let media: NSPopUpButton = try control("media", in: editor)
        media.selectItem(withTag: 1)
        #expect(saved.isEmpty)
        let save: NSButton = try control("save", in: editor)
        save.performClick(nil)
        #expect(saved == [KeyboardRoutingPreferences(
            brightness: .macOS, missionControl: .macOS, spotlight: .omarchy,
            dictation: .omarchy, doNotDisturb: .omarchy, media: .omarchy
        )])
        #expect(closed == 1)
    }

    @Test("Use Defaults resets only the draft and Cancel never publishes")
    func defaultsAndCancel() throws {
        _ = NSApplication.shared
        var saved: [KeyboardRoutingPreferences] = []
        let editor = KeyboardRoutingEditor(
            preferences: KeyboardRoutingPreferences(
                brightness: .omarchy, missionControl: .omarchy, spotlight: .omarchy,
                dictation: .omarchy, doNotDisturb: .omarchy
            ),
            save: { saved.append($0) },
            didClose: {}
        )
        let missionControl: NSPopUpButton = try control("mission-control", in: editor)
        #expect(missionControl.selectedItem?.tag == 1)
        let defaults: NSButton = try control("defaults", in: editor)
        defaults.performClick(nil)
        #expect(missionControl.selectedItem?.tag == 0)
        let cancel: NSButton = try control("cancel", in: editor)
        cancel.performClick(nil)
        #expect(saved.isEmpty)
    }

    private func control<T: NSView>(_ name: String, in editor: KeyboardRoutingEditor) throws -> T {
        func find(in view: NSView) -> T? {
            if view.identifier?.rawValue == "keyboard-routing-\(name)" { return view as? T }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        let content = try #require(editor.window.contentView)
        return try #require(find(in: content))
    }
}
