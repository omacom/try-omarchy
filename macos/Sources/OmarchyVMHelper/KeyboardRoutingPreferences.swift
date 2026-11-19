import Foundation

/// Which side receives one of the Mac's dedicated keys while Omarchy is focused.
enum KeyRoute: String, Codable, CaseIterable {
    case macOS
    case omarchy
}

/// Modifier keys held for a shortcut, in macOS's display order.
struct ShortcutModifiers: OptionSet, Hashable {
    let rawValue: Int

    static let control = Self(rawValue: 1 << 0)
    static let option = Self(rawValue: 1 << 1)
    static let shift = Self(rawValue: 1 << 2)
    static let command = Self(rawValue: 1 << 3)

    private static let names: [(Self, name: String, hostKey: String, symbol: String)] = [
        (.control, "control", "ctrl", "⌃"),
        (.option, "option", "opt", "⌥"),
        (.shift, "shift", "shift", "⇧"),
        (.command, "command", "cmd", "⌘"),
    ]

    var symbols: String { Self.names.filter { contains($0.0) }.map(\.symbol).joined() }
    var hostKeyNames: [String] { Self.names.filter { contains($0.0) }.map(\.hostKey) }
    var names: [String] { Self.names.filter { contains($0.0) }.map(\.name) }

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Nil when a name is unknown.
    init?(names: [String]) {
        var modifiers: Self = []
        for name in names {
            guard let match = Self.names.first(where: { $0.name == name }) else { return nil }
            modifiers.insert(match.0)
        }
        self = modifiers
    }
}

/// A shortcut that stays with macOS while Omarchy is focused, such as
/// Control-Right Arrow to move to the next Space.
struct KeptShortcut: Hashable {
    static let keyCodes = 0...255

    let keyCode: Int
    let modifiers: ShortcutModifiers
    /// The key as the keyboard labels it, such as → or A.
    let key: String
    /// What the shortcut does in macOS, when it's one of macOS's own.
    var name: String?

    var symbols: String { modifiers.symbols + key }

    /// QEMU's host-keys form, such as 124+ctrl.
    var hostKey: String { ([String(keyCode)] + modifiers.hostKeyNames).joined(separator: "+") }

    func isSameKeys(as other: KeptShortcut) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }
}

struct KeyboardRoutingPreferences: Equatable {
    var brightness: KeyRoute
    var missionControl: KeyRoute
    var spotlight: KeyRoute
    var dictation: KeyRoute = .macOS
    var doNotDisturb: KeyRoute = .macOS
    var media: KeyRoute = .macOS
    var shortcuts: [KeptShortcut] = []
    /// Gives macOS the keyboard and the mouse until Omarchy is focused again.
    var releaseShortcut: KeptShortcut = Self.defaultReleaseShortcut

    static let defaults = Self(brightness: .macOS, missionControl: .macOS, spotlight: .macOS)
    /// Control-Option-G, which QEMU already reserves to release the mouse.
    static let defaultReleaseShortcut = KeptShortcut(keyCode: 5, modifiers: [.control, .option], key: "G")
    /// Well under the 64 QEMU takes.
    static let maximumShortcuts = 32

    // An Apple keyboard in its default mode sends these caps as plain key
    // events with dedicated keycodes, not as F-keys. With "Use F1, F2, etc.
    // as standard function keys" enabled they arrive as F-keys instead and
    // are unaffected.
    static let brightnessKeycodes = [144, 145]
    static let missionControlKeycodes = [160]
    static let spotlightKeycodes = [131, 177]
    static let dictationKeycodes = [176]
    static let doNotDisturbKeycodes = [178]

    /// Keycodes that stay with macOS, in the order the launcher publishes them.
    var hostKeycodes: [Int] {
        var keycodes: [Int] = []
        if brightness == .macOS { keycodes += Self.brightnessKeycodes }
        if missionControl == .macOS { keycodes += Self.missionControlKeycodes }
        if spotlight == .macOS { keycodes += Self.spotlightKeycodes }
        if dictation == .macOS { keycodes += Self.dictationKeycodes }
        if doNotDisturb == .macOS { keycodes += Self.doNotDisturbKeycodes }
        return keycodes.sorted()
    }

    /// Everything that stays with macOS, in QEMU's host-keys form. The
    /// release shortcut wins over a kept shortcut with the same keys.
    var hostKeys: [String] {
        var seen: Set<String> = [releaseShortcut.hostKey]
        let shortcutKeys = shortcuts.map(\.hostKey).filter { seen.insert($0).inserted }
        return hostKeycodes.map(String.init) + shortcutKeys
    }
}

struct KeyboardRoutingPreferenceStore {
    static let key = "keyboardRoutingPreferences"
    static let schemaVersion = 1

    private let storage: any LauncherSettingsStorage

    init(storage: any LauncherSettingsStorage) {
        self.storage = storage
    }

    init(defaults: UserDefaults) {
        self.init(storage: defaults)
    }

    func load() -> KeyboardRoutingPreferences {
        guard let data = storage.settingData(forKey: Self.key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schemaVersion == Self.schemaVersion else {
            return .defaults
        }
        let releaseShortcut = payload.releaseShortcut?.payload?.shortcut ?? KeyboardRoutingPreferences.defaultReleaseShortcut
        return KeyboardRoutingPreferences(
            brightness: payload.brightness,
            missionControl: payload.missionControl,
            spotlight: payload.spotlight,
            dictation: payload.dictation ?? .macOS,
            doNotDisturb: payload.doNotDisturb ?? .macOS,
            media: payload.media ?? .macOS,
            shortcuts: Array((payload.shortcuts ?? []).compactMap { $0.payload?.shortcut }
                .filter { !$0.isSameKeys(as: releaseShortcut) }
                .prefix(KeyboardRoutingPreferences.maximumShortcuts)),
            releaseShortcut: releaseShortcut
        )
    }

    func save(_ preferences: KeyboardRoutingPreferences) {
        let payload = Payload(
            schemaVersion: Self.schemaVersion,
            brightness: preferences.brightness,
            missionControl: preferences.missionControl,
            spotlight: preferences.spotlight,
            dictation: preferences.dictation,
            doNotDisturb: preferences.doNotDisturb,
            media: preferences.media,
            shortcuts: preferences.shortcuts.map(SavedShortcut.init),
            releaseShortcut: SavedShortcut(preferences.releaseShortcut)
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? storage.setSettingData(data, forKey: Self.key)
    }

    private struct Payload: Codable {
        let schemaVersion: Int
        let brightness: KeyRoute
        let missionControl: KeyRoute
        let spotlight: KeyRoute
        let dictation: KeyRoute?
        let doNotDisturb: KeyRoute?
        let media: KeyRoute?
        let shortcuts: [SavedShortcut]?
        let releaseShortcut: SavedShortcut?
    }

    /// Nil for an entry that doesn't decode, so one bad entry can't reset
    /// every other preference.
    private struct SavedShortcut: Codable {
        let payload: ShortcutPayload?

        init(_ shortcut: KeptShortcut) {
            payload = ShortcutPayload(shortcut)
        }

        init(from decoder: any Decoder) throws {
            payload = try? ShortcutPayload(from: decoder)
        }

        func encode(to encoder: any Encoder) throws {
            try payload.encode(to: encoder)
        }
    }

    private struct ShortcutPayload: Codable {
        let keyCode: Int
        let modifiers: [String]
        let key: String
        let name: String?

        init(_ shortcut: KeptShortcut) {
            keyCode = shortcut.keyCode
            modifiers = shortcut.modifiers.names
            key = shortcut.key
            name = shortcut.name
        }

        /// Nil for an entry QEMU couldn't take, so one bad entry can't block the launch.
        var shortcut: KeptShortcut? {
            guard KeptShortcut.keyCodes.contains(keyCode),
                  let modifiers = ShortcutModifiers(names: modifiers),
                  !modifiers.isEmpty, !key.isEmpty else { return nil }
            return KeptShortcut(keyCode: keyCode, modifiers: modifiers, key: key, name: name)
        }
    }
}

struct KeyboardRoutingLaunchConfiguration: Equatable {
    static let hostKeysEnvironmentKey = "OMARCHY_QEMU_GPU_HOST_KEYS"
    static let mediaKeysEnvironmentKey = "OMARCHY_QEMU_GPU_MEDIA_KEYS"
    static let releaseKeyEnvironmentKey = "OMARCHY_QEMU_GPU_RELEASE_KEY"

    let environment: [String: String]

    static func make(
        baseEnvironment: [String: String],
        preferences: KeyboardRoutingPreferences
    ) -> Self {
        var environment = baseEnvironment
        environment[hostKeysEnvironmentKey] = preferences.hostKeys.joined(separator: ",")
        environment[mediaKeysEnvironmentKey] = preferences.media == .omarchy ? "1" : "0"
        environment[releaseKeyEnvironmentKey] = preferences.releaseShortcut.hostKey
        return Self(environment: environment)
    }
}
