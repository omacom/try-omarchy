import Foundation

/// How much host RAM the guest boots with. The value is a boot-time QEMU
/// setting (`-m`), so a change always applies on the next launch; it is never
/// baked into the guest image or the persistent VM data.
enum MemoryPolicy {
    /// The baseline in the guest manifest and legacy saved preferences.
    static let defaultMemoryMiB = 4096
    static let minimumMemoryMiB = 2048
    static let hostHeadroomMiB = 4096
    static let recommendedHostHeadroomMiB = 8192
    static let environmentKey = "OMARCHY_QEMU_GPU_MEMORY_MIB"

    static func hostMemoryMiB() -> Int {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))
    }

    static func recommendedMemoryMiB(hostMemoryMiB: Int) -> Int {
        hostMemoryMiB >= 16384 ? 8192 : defaultMemoryMiB
    }

    /// Keep at least 4 GiB for macOS, with the baseline always available on
    /// smaller hosts. Continue in 4 GiB steps instead of stopping at 16 GiB.
    static func allowedChoicesMiB(hostMemoryMiB: Int) -> [Int] {
        let maximum = max(defaultMemoryMiB, hostMemoryMiB - hostHeadroomMiB)
        return [4096, 6144, 8192].filter { $0 <= maximum }
            + Array(stride(from: 12288, through: maximum, by: 4096))
    }

    static func resolvedMemoryMiB(preferredMiB: Int, hostMemoryMiB: Int) -> Int {
        allowedChoicesMiB(hostMemoryMiB: hostMemoryMiB).contains(preferredMiB)
            ? preferredMiB
            : recommendedMemoryMiB(hostMemoryMiB: hostMemoryMiB)
    }

    static func maySlowHost(memoryMiB: Int, hostMemoryMiB: Int) -> Bool {
        memoryMiB > recommendedMemoryMiB(hostMemoryMiB: hostMemoryMiB)
            && hostMemoryMiB - memoryMiB < recommendedHostHeadroomMiB
    }

    static func choiceTitle(memoryMiB: Int, hostMemoryMiB: Int) -> String {
        let label = displayLabel(memoryMiB: memoryMiB)
        if memoryMiB == recommendedMemoryMiB(hostMemoryMiB: hostMemoryMiB) {
            return "\(label) · default"
        }
        return maySlowHost(memoryMiB: memoryMiB, hostMemoryMiB: hostMemoryMiB)
            ? "\(label) · may slow macOS" : label
    }

    static func displayLabel(memoryMiB: Int) -> String {
        memoryMiB % 1024 == 0
            ? "\(memoryMiB / 1024) GiB"
            : "\(memoryMiB) MiB"
    }
}

struct MemoryPreferences: Equatable {
    var memoryMiB: Int

    static let defaults = Self(memoryMiB: MemoryPolicy.defaultMemoryMiB)
}

struct MemoryPreferenceStore {
    static let key = "memoryPreferences"
    static let schemaVersion = 1

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> MemoryPreferences {
        guard let data = defaults.data(forKey: Self.key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schemaVersion == Self.schemaVersion else {
            return .defaults
        }
        return MemoryPreferences(memoryMiB: payload.memoryMiB)
    }

    func save(_ preferences: MemoryPreferences) {
        let payload = Payload(
            schemaVersion: Self.schemaVersion,
            memoryMiB: preferences.memoryMiB
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private struct Payload: Codable {
        let schemaVersion: Int
        let memoryMiB: Int
    }
}

struct MemoryLaunchConfiguration: Equatable {
    let environment: [String: String]

    static func make(
        baseEnvironment: [String: String],
        preferences: MemoryPreferences,
        hostMemoryMiB: Int
    ) -> Self {
        var environment = baseEnvironment
        environment[MemoryPolicy.environmentKey] = String(
            MemoryPolicy.resolvedMemoryMiB(
                preferredMiB: preferences.memoryMiB,
                hostMemoryMiB: hostMemoryMiB
            )
        )
        return Self(environment: environment)
    }
}
