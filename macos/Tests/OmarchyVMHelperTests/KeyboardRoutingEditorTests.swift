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

    @Test("Quick picks and removals edit the draft, and Save publishes the shortcuts")
    func shortcuts() throws {
        _ = NSApplication.shared
        var saved: [KeyboardRoutingPreferences] = []
        let left = KeptShortcut(keyCode: 123, modifiers: .control, key: "←", name: "Move left a space")
        let right = KeptShortcut(keyCode: 124, modifiers: .control, key: "→", name: "Move right a space")
        let up = KeptShortcut(keyCode: 126, modifiers: .control, key: "↑", name: "Mission Control")
        var preferences = KeyboardRoutingPreferences.defaults
        preferences.shortcuts = [right]
        let editor = KeyboardRoutingEditor(
            preferences: preferences,
            picks: [
                MacSystemShortcuts.Pick(title: "Switch Spaces", shortcuts: [left, right]),
                MacSystemShortcuts.Pick(title: "Mission Control", shortcuts: [up]),
            ],
            save: { saved.append($0) },
            didClose: {}
        )
        let add: NSPopUpButton = try control("add-shortcut", in: editor)
        #expect(add.itemTitles == ["Add", "Switch Spaces  ⌃← ⌃→", "Mission Control  ⌃↑", "", "Record Shortcut…"])
        #expect(add.item(at: 1)?.isEnabled == true)

        choose(0, in: add)
        #expect(editor.shortcuts == [right, left])
        #expect(add.item(at: 1)?.isEnabled == false)
        choose(1, in: add)
        #expect(editor.shortcuts == [right, left, up])

        let remove: NSButton = try control("remove-shortcut-0", in: editor)
        remove.performClick(nil)
        #expect(editor.shortcuts == [left, up])

        let save: NSButton = try control("save", in: editor)
        save.performClick(nil)
        #expect(saved.map(\.shortcuts) == [[left, up]])
    }

    @Test("Use Defaults clears the kept shortcuts")
    func defaultsClearShortcuts() throws {
        _ = NSApplication.shared
        var preferences = KeyboardRoutingPreferences.defaults
        preferences.shortcuts = [KeptShortcut(keyCode: 124, modifiers: .control, key: "→")]
        var saved: [KeyboardRoutingPreferences] = []
        let editor = KeyboardRoutingEditor(
            preferences: preferences, picks: [], save: { saved.append($0) }, didClose: {}
        )
        let add: NSPopUpButton = try control("add-shortcut", in: editor)
        #expect(add.itemTitles == ["Add", "Record Shortcut…"])
        let defaults: NSButton = try control("defaults", in: editor)
        defaults.performClick(nil)
        #expect(editor.shortcuts.isEmpty)
        let save: NSButton = try control("save", in: editor)
        save.performClick(nil)
        #expect(saved == [.defaults])
    }

    private func choose(_ tag: Int, in popup: NSPopUpButton) {
        popup.selectItem(withTag: tag)
        _ = popup.target?.perform(popup.action, with: popup)
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
