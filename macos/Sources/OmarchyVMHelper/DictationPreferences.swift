import Foundation

struct DictationPreferences: Equatable {
    var isEnabled: Bool

    static let defaults = Self(isEnabled: true)
}

struct DictationPreferenceStore {
    static let key = "dictationPreferences"
    static let schemaVersion = 1

    private let storage: any LauncherSettingsStorage

    init(storage: any LauncherSettingsStorage) {
        self.storage = storage
    }

    init(defaults: UserDefaults) {
        self.init(storage: defaults)
    }

    func load() -> DictationPreferences {
        guard let data = storage.settingData(forKey: Self.key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schemaVersion == Self.schemaVersion else {
            return .defaults
        }
        return DictationPreferences(isEnabled: payload.isEnabled)
    }

    func save(_ preferences: DictationPreferences) {
        let payload = Payload(schemaVersion: Self.schemaVersion, isEnabled: preferences.isEnabled)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? storage.setSettingData(data, forKey: Self.key)
    }

    private struct Payload: Codable {
        let schemaVersion: Int
        let isEnabled: Bool
    }
}

/// The launcher adds the dictation port only for "1". A Mac that can't run
/// dictation (DictationSupport.isAvailable) always gets "0", whatever was
/// saved, so the choice comes back after an upgrade.
struct DictationLaunchConfiguration: Equatable {
    static let environmentKey = "OMARCHY_QEMU_GPU_DICTATION"

    let environment: [String: String]

    static func make(
        baseEnvironment: [String: String],
        preferences: DictationPreferences,
        isSupported: Bool
    ) -> Self {
        var environment = baseEnvironment
        environment[environmentKey] = isSupported && preferences.isEnabled ? "1" : "0"
        return Self(environment: environment)
    }
}
