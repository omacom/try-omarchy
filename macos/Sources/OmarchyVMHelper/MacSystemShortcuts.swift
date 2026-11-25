import AppKit
import Carbon

/// macOS's own shortcuts that people most often want to keep while Omarchy
/// is focused, bound as the person set them in System Settings.
enum MacSystemShortcuts {
    struct Pick: Equatable {
        let title: String
        let shortcuts: [KeptShortcut]
    }

    private struct Definition {
        let id: Int
        let name: String
        let keyCode: Int
        let modifiers: ShortcutModifiers
        let enabledByDefault: Bool
    }

    private static let moveLeft = Definition(
        id: 79, name: "Move left a space", keyCode: kVK_LeftArrow, modifiers: .control, enabledByDefault: true)
    private static let moveRight = Definition(
        id: 81, name: "Move right a space", keyCode: kVK_RightArrow, modifiers: .control, enabledByDefault: true)
    private static let missionControl = Definition(
        id: 32, name: "Mission Control", keyCode: kVK_UpArrow, modifiers: .control, enabledByDefault: true)
    private static let applicationWindows = Definition(
        id: 33, name: "Application windows", keyCode: kVK_DownArrow, modifiers: .control, enabledByDefault: true)
    private static let desktops: [Definition] = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
    ].enumerated().map { index, keyCode in
        Definition(id: 118 + index, name: "Switch to Desktop \(index + 1)", keyCode: keyCode,
                   modifiers: .control, enabledByDefault: false)
    }

    private static let all = [moveLeft, moveRight, missionControl, applicationWindows] + desktops

    /// The quick picks offered in the Keyboard sheet. A pick whose shortcuts
    /// are all turned off in macOS is left out.
    static func picks(hotKeys: [String: Any]? = readHotKeys()) -> [Pick] {
        let groups: [(String, [Definition])] = [
            ("Switch Spaces", [moveLeft, moveRight]),
            ("Mission Control", [missionControl]),
            ("Application Windows", [applicationWindows]),
            ("Switch to Desktops", desktops),
        ]
        return groups.compactMap { title, definitions in
            let shortcuts = definitions.compactMap { shortcut(for: $0, hotKeys: hotKeys) }
            return shortcuts.isEmpty ? nil : Pick(title: title, shortcuts: shortcuts)
        }
    }

    /// macOS's name for a recorded shortcut, when it's one of these.
    static func name(of shortcut: KeptShortcut, hotKeys: [String: Any]? = readHotKeys()) -> String? {
        all.lazy
            .compactMap { self.shortcut(for: $0, hotKeys: hotKeys) }
            .first { $0.isSameKeys(as: shortcut) }?
            .name
    }

    /// System Settings keeps only the shortcuts a person changed, under
    /// AppleSymbolicHotKeys, keyed by an ID as a string. Each holds
    /// `enabled` and `value.parameters`: the character, the keycode and
    /// NSEvent modifier flags.
    static func readHotKeys() -> [String: Any]? {
        CFPreferencesCopyAppValue(
            "AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString
        ) as? [String: Any]
    }

    private static func shortcut(for definition: Definition, hotKeys: [String: Any]?) -> KeptShortcut? {
        guard let entry = hotKeys?[String(definition.id)] as? [String: Any] else {
            guard definition.enabledByDefault else { return nil }
            return KeptShortcut(
                keyCode: definition.keyCode, modifiers: definition.modifiers,
                key: KeyLabels.label(keyCode: definition.keyCode), name: definition.name
            )
        }
        guard (entry["enabled"] as? Bool) == true,
              let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Int], parameters.count == 3,
              KeptShortcut.keyCodes.contains(parameters[1]) else { return nil }
        let modifiers = ShortcutModifiers(NSEvent.ModifierFlags(rawValue: UInt(truncatingIfNeeded: parameters[2])))
        guard !modifiers.isEmpty else { return nil }
        return KeptShortcut(
            keyCode: parameters[1], modifiers: modifiers,
            key: KeyLabels.label(keyCode: parameters[1]), name: definition.name
        )
    }
}

extension ShortcutModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.command) { insert(.command) }
    }
}

/// How the keyboard labels a key, as macOS shows it in menus.
enum KeyLabels {
    private static let named: [Int: String] = [
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Space: "Space",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    static func label(keyCode: Int) -> String {
        if let name = named[keyCode] { return name }
        if let character = typedCharacter(keyCode: keyCode) { return character.uppercased() }
        return "Key \(keyCode)"
    }

    /// The character the current keyboard layout types for the key alone.
    private static func typedCharacter(keyCode: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { bytes -> OSStatus in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState,
                characters.count, &length, &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length)
        guard let scalar = text.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar),
              !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return text
    }
}
