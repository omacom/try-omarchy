import AppKit
import Testing
@testable import OmarchyVMHelper

@Suite("macOS shortcut picks")
struct MacSystemShortcutsTests {
    private let control = Int(NSEvent.ModifierFlags.control.rawValue)
    private let shift = Int(NSEvent.ModifierFlags.shift.rawValue)
    private let function = Int(NSEvent.ModifierFlags.function.rawValue)

    @Test("Without changes in System Settings, picks are macOS's default Spaces shortcuts")
    func defaults() {
        let picks = MacSystemShortcuts.picks(hotKeys: nil)
        #expect(picks.map(\.title) == ["Switch Spaces", "Mission Control", "Application Windows"])
        #expect(picks[0].shortcuts == [
            KeptShortcut(keyCode: 123, modifiers: .control, key: "←", name: "Move left a space"),
            KeptShortcut(keyCode: 124, modifiers: .control, key: "→", name: "Move right a space"),
        ])
        #expect(picks[1].shortcuts.map(\.symbols) == ["⌃↑"])
        #expect(picks[2].shortcuts.map(\.symbols) == ["⌃↓"])
    }

    @Test("Picks follow the shortcuts as changed in System Settings")
    func followsSystemSettings() {
        let hotKeys: [String: Any] = [
            "79": ["enabled": false, "value": ["parameters": [65535, 123, control | function], "type": "standard"]],
            "81": ["enabled": true, "value": ["parameters": [65535, 124, control | shift | function], "type": "standard"]],
            "32": ["enabled": false],
            "33": ["enabled": true, "value": ["parameters": [65535, 125, 0], "type": "standard"]],
            "118": ["enabled": true, "value": ["parameters": [49, 18, control], "type": "standard"]],
            "119": ["enabled": true, "value": ["parameters": [50, 300, control], "type": "standard"]],
        ]
        let picks = MacSystemShortcuts.picks(hotKeys: hotKeys)
        #expect(picks.map(\.title) == ["Switch Spaces", "Switch to Desktops"])
        #expect(picks[0].shortcuts == [
            KeptShortcut(keyCode: 124, modifiers: [.control, .shift], key: "→", name: "Move right a space"),
        ])
        #expect(picks[1].shortcuts.map(\.keyCode) == [18])
        #expect(picks[1].shortcuts.map(\.modifiers) == [.control])
        #expect(picks[1].shortcuts.map(\.name) == ["Switch to Desktop 1"])
    }

    @Test("A recorded shortcut gets macOS's name when it's one of these")
    func names() {
        #expect(MacSystemShortcuts.name(
            of: KeptShortcut(keyCode: 126, modifiers: .control, key: "↑"), hotKeys: nil
        ) == "Mission Control")
        #expect(MacSystemShortcuts.name(
            of: KeptShortcut(keyCode: 126, modifiers: [.control, .option], key: "↑"), hotKeys: nil
        ) == nil)
    }

    @Test("Recording needs a modifier, and Escape alone cancels")
    func recorderRules() {
        #expect(ShortcutRecorder.classify(keyCode: 124, flags: [.control, .function, .numericPad])
            == .shortcut(keyCode: 124, modifiers: .control))
        #expect(ShortcutRecorder.classify(keyCode: 0, flags: [.command, .shift, .capsLock])
            == .shortcut(keyCode: 0, modifiers: [.shift, .command]))
        #expect(ShortcutRecorder.classify(keyCode: 0, flags: [.capsLock]) == .needsModifier)
        #expect(ShortcutRecorder.classify(keyCode: 103, flags: [.function]) == .needsModifier)
        #expect(ShortcutRecorder.classify(keyCode: 53, flags: []) == .cancel)
        #expect(ShortcutRecorder.classify(keyCode: 53, flags: .command) == .shortcut(keyCode: 53, modifiers: .command))
    }
}
