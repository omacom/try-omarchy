import Darwin
import Foundation

/// Startup consent belongs to the VM workspace, not the app's preferences domain.
final class StartupPreferenceStore {
    static let fileName = "launcher-settings.json"
    private var pendingChoices: [URL: Bool] = [:]

    func load(storageRoot: URL?) -> Bool {
        guard let storageRoot else { return false }
        if let pending = pendingChoices[storageRoot] { return pending }
        let url = storageRoot.appendingPathComponent(Self.fileName)
        guard StorageLocationPolicy.hasValidRootMarker(in: storageRoot),
              isPrivateEntry(storageRoot, type: S_IFDIR, permissions: 0o700),
              isPrivateEntry(url, type: S_IFREG, permissions: 0o600),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 4096,
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schemaVersion == 1 else { return false }
        return payload.startAutomatically
    }

    func save(_ enabled: Bool, storageRoot: URL) throws {
        // Leave an empty custom folder untouched until the storage backend owns
        // it. Otherwise its new settings file would make folder validation fail.
        let marker = storageRoot.appendingPathComponent(StorageLocationPolicy.rootMarkerName)
        var information = stat()
        if lstat(marker.path, &information) != 0, errno == ENOENT {
            pendingChoices[storageRoot] = enabled
            return
        }
        try write(enabled, storageRoot: storageRoot)
        pendingChoices.removeValue(forKey: storageRoot)
    }

    /// Retain a choice made before the first VM launch once storage is ready.
    func persistPendingChoice(storageRoot: URL) throws {
        guard let enabled = pendingChoices[storageRoot] else { return }
        try write(enabled, storageRoot: storageRoot)
        pendingChoices.removeValue(forKey: storageRoot)
    }

    private func write(_ enabled: Bool, storageRoot: URL) throws {
        guard StorageLocationPolicy.hasValidRootMarker(in: storageRoot),
              isPrivateEntry(storageRoot, type: S_IFDIR, permissions: 0o700) else {
            throw HelperError.io("The VM workspace is unavailable or is not private to this user.")
        }
        let url = storageRoot.appendingPathComponent(Self.fileName)
        var information = stat()
        if lstat(url.path, &information) == 0 {
            guard isPrivateEntry(url, type: S_IFREG, permissions: 0o600) else {
                throw HelperError.io("The launcher settings file is not a private regular file.")
            }
        } else if errno != ENOENT {
            throw HelperError.io("The launcher settings file could not be checked.")
        }
        let data = try JSONEncoder().encode(Payload(schemaVersion: 1, startAutomatically: enabled))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func isPrivateEntry(_ url: URL, type: mode_t, permissions: mode_t) -> Bool {
        var information = stat()
        return lstat(url.path, &information) == 0
            && information.st_mode & S_IFMT == type
            && information.st_uid == getuid()
            && information.st_mode & 0o777 == permissions
    }

    private struct Payload: Codable {
        let schemaVersion: Int
        let startAutomatically: Bool
    }
}

enum StartupPolicy {
    static func shouldStartAutomatically(
        isEnabled: Bool,
        hasExistingVM: Bool,
        optionKeyHeld: Bool,
        initialArguments: [String],
        requiresVMFixReview: Bool = false
    ) -> Bool {
        let resetRequested = initialArguments.first == QEMUGPUStorageOption.resetStorage.rawValue
            || initialArguments.first == QEMUGPUStorageOption.resetStorageOnly.rawValue
        return isEnabled && hasExistingVM && !optionKeyHeld && !resetRequested
            && initialArguments.first != QEMUGPUStorageOption.ephemeral.rawValue
            && !requiresVMFixReview
    }
}
