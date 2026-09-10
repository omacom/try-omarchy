import Foundation

struct StartupPreferenceStore {
    static let key = "startAutomatically"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> Bool {
        defaults.bool(forKey: Self.key)
    }

    func save(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.key)
    }
}

enum StartupPolicy {
    static func shouldStartAutomatically(
        isEnabled: Bool,
        optionKeyHeld: Bool,
        initialArguments: [String]
    ) -> Bool {
        let resetRequested = initialArguments.first == QEMUGPUStorageOption.resetStorage.rawValue
            || initialArguments.first == QEMUGPUStorageOption.resetStorageOnly.rawValue
        return isEnabled && !optionKeyHeld && !resetRequested
    }
}
