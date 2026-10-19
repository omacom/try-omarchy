import Foundation

struct HDRPreferences: Equatable {
    var isEnabled: Bool

    static let defaults = Self(isEnabled: false)
}

struct HDRPreferenceStore {
    static let key = "hdrPreferences"
    static let schemaVersion = 1

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> HDRPreferences {
        guard let data = defaults.data(forKey: Self.key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schemaVersion == Self.schemaVersion else {
            return .defaults
        }
        return HDRPreferences(isEnabled: payload.isEnabled)
    }

    func save(_ preferences: HDRPreferences) {
        let payload = Payload(
            schemaVersion: Self.schemaVersion,
            isEnabled: preferences.isEnabled
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private struct Payload: Codable {
        let schemaVersion: Int
        let isEnabled: Bool
    }
}

struct HDRLaunchConfiguration: Equatable {
    static let environmentKey = "OMARCHY_NATIVE_OPENGL_HDR"

    let environment: [String: String]

    static func make(
        baseEnvironment: [String: String],
        preferences: HDRPreferences
    ) -> Self {
        var environment = baseEnvironment
        environment[environmentKey] = preferences.isEnabled ? "1" : "0"
        return Self(environment: environment)
    }
}
