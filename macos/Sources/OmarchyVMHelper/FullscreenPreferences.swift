import Foundation

struct FullscreenPreferences: Equatable {
    var isImmersive: Bool
    /// Full screen uses the strip beside a MacBook's camera notch, where
    /// Omarchy's bar then sits (docs/camera-notch.md). Off, it stays below the
    /// notch. Macs without a notch never show or use it.
    var usesNotch: Bool = true

    static let defaults = Self(isImmersive: true, usesNotch: true)
}

struct FullscreenPreferenceStore {
    static let key = "fullscreenPreferences"
    static let schemaVersion = 1

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> FullscreenPreferences {
        guard let data = defaults.data(forKey: Self.key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schemaVersion == Self.schemaVersion else {
            return .defaults
        }
        return FullscreenPreferences(
            isImmersive: payload.isImmersive,
            usesNotch: payload.usesNotch ?? FullscreenPreferences.defaults.usesNotch
        )
    }

    func save(_ preferences: FullscreenPreferences) {
        let payload = Payload(
            schemaVersion: Self.schemaVersion,
            isImmersive: preferences.isImmersive,
            usesNotch: preferences.usesNotch
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// `usesNotch` is optional so settings saved before it existed keep their
    /// Immersive choice and take the notch's default.
    private struct Payload: Codable {
        let schemaVersion: Int
        let isImmersive: Bool
        let usesNotch: Bool?
    }
}

struct FullscreenLaunchConfiguration: Equatable {
    static let immersiveEnvironmentKey = "OMARCHY_QEMU_GPU_IMMERSIVE"
    static let notchEnvironmentKey = "OMARCHY_QEMU_GPU_NOTCH"

    let environment: [String: String]

    static func make(
        baseEnvironment: [String: String],
        preferences: FullscreenPreferences
    ) -> Self {
        var environment = baseEnvironment
        environment.removeValue(forKey: immersiveEnvironmentKey)
        environment[immersiveEnvironmentKey] = preferences.isImmersive ? "1" : "0"
        environment[notchEnvironmentKey] = preferences.usesNotch ? "1" : "0"
        return Self(environment: environment)
    }
}
