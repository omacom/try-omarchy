import Foundation

struct VMResources: Codable, Equatable {
    var cpuCount: Int
    var memoryGiB: Int
}

struct VMResourceLimits: Equatable {
    static let minimumCPUCount = 4
    static let defaultMemoryGiB = MemoryPolicy.defaultMemoryMiB / 1024
    static let bytesPerGiB: UInt64 = 1 << 30

    let hostCPUCount: Int
    let hostMemoryBytes: UInt64

    static var current: Self {
        Self(
            hostCPUCount: ProcessInfo.processInfo.processorCount,
            hostMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
    }

    var cpuRange: ClosedRange<Int> {
        Self.minimumCPUCount...max(Self.minimumCPUCount, hostCPUCount)
    }

    var memoryChoicesGiB: [Int] {
        MemoryPolicy.allowedChoicesMiB(
            hostMemoryMiB: Int(hostMemoryBytes / (1 << 20))
        ).map { $0 / 1024 }
    }

    var defaults: VMResources {
        VMResources(cpuCount: min(8, cpuRange.upperBound), memoryGiB: Self.defaultMemoryGiB)
    }

    /// Resolve each value independently when a saved choice no longer fits
    /// this Mac. The stored choice is retained for a later move back.
    func resolve(_ saved: VMResources?) -> VMResources {
        guard let saved else { return defaults }
        return VMResources(
            cpuCount: cpuRange.contains(saved.cpuCount) ? saved.cpuCount : defaults.cpuCount,
            memoryGiB: memoryChoicesGiB.contains(saved.memoryGiB) ? saved.memoryGiB : defaults.memoryGiB
        )
    }

    func validate(cpuCount: String, memoryGiB: String) throws -> VMResources {
        guard let cpus = Self.wholeNumber(cpuCount), cpuRange.contains(cpus) else {
            throw VMResourceInputError.invalidCPUCount(cpuRange.upperBound)
        }
        guard let memory = Self.wholeNumber(memoryGiB), memoryChoicesGiB.contains(memory) else {
            throw VMResourceInputError.invalidMemory(memoryChoicesGiB)
        }
        return VMResources(cpuCount: cpus, memoryGiB: memory)
    }

    private static func wholeNumber(_ text: String) -> Int? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return Int(text)
    }
}

enum VMResourceInputError: LocalizedError {
    case invalidCPUCount(Int)
    case invalidMemory([Int])

    var errorDescription: String? {
        switch self {
        case .invalidCPUCount(let maximum):
            "Processor cores must be a whole number from \(VMResourceLimits.minimumCPUCount) to \(maximum)."
        case .invalidMemory(let choices):
            "Choose \(choices.map(String.init).joined(separator: ", ")) GiB of memory."
        }
    }
}

struct VMResourcePreferenceStore {
    static let key = "vmResourcePreferences"
    static let schemaVersion = 1

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> VMResources? {
        // Adopt #82's saved memory only until the first Resources save. Keep
        // the original preference untouched, including on a smaller host.
        if defaults.object(forKey: Self.key) == nil,
           defaults.object(forKey: MemoryPreferenceStore.key) != nil {
            let memoryMiB = MemoryPreferenceStore(defaults: defaults).load().memoryMiB
            return VMResources(
                cpuCount: 8,
                memoryGiB: (MemoryPolicy.choicesMiB.contains(memoryMiB)
                    ? memoryMiB : MemoryPolicy.defaultMemoryMiB) / 1024
            )
        }
        guard let data = defaults.data(forKey: Self.key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schemaVersion == Self.schemaVersion else { return nil }
        return payload.resources
    }

    func save(_ resources: VMResources) {
        let payload = Payload(schemaVersion: Self.schemaVersion, resources: resources)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private struct Payload: Codable {
        let schemaVersion: Int
        let resources: VMResources
    }
}

struct VMResourceLaunchConfiguration: Equatable {
    static let cpuEnvironmentKey = "OMARCHY_QEMU_GPU_CPUS"
    static let memoryEnvironmentKey = MemoryPolicy.environmentKey

    let environment: [String: String]

    static func make(
        baseEnvironment: [String: String],
        preferences: VMResources?,
        limits: VMResourceLimits
    ) -> Self {
        let resources = limits.resolve(preferences)
        var environment = baseEnvironment
        environment[cpuEnvironmentKey] = String(resources.cpuCount)
        environment[memoryEnvironmentKey] = String(resources.memoryGiB * 1024)
        return Self(environment: environment)
    }
}
