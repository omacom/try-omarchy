import Darwin
import Foundation

protocol LauncherSettingsStorage: AnyObject {
    func settingData(forKey key: String) -> Data?
    func setSettingData(_ data: Data, forKey key: String) throws
    func removeSetting(forKey key: String) throws
    /// Set when values are stored but cannot be trusted, so their absence
    /// must not be read as the default.
    var untrustedReason: String? { get }
}

extension UserDefaults: LauncherSettingsStorage {
    func settingData(forKey key: String) -> Data? { data(forKey: key) }
    func setSettingData(_ data: Data, forKey key: String) { set(data, forKey: key) }
    func removeSetting(forKey key: String) { removeObject(forKey: key) }
    var untrustedReason: String? { nil }
}

/// A private, versioned JSON file of settings. UserDefaults follow the identity
/// of the app that runs the kit, so the full app and the run mode keep their
/// settings in files that both read.
///
/// The VM's settings wait for the launcher to mark its folder: a file in an
/// empty folder someone picked would make the folder look used. Until then the
/// full app keeps them in `legacy`, where its older settings already are.
///
/// A key the file has, even as null, wins; otherwise the legacy value applies.
/// An older full app can still change `legacy` after another kit has read it,
/// so only the app that owns `legacy` (`legacyIsWritable`) moves values into
/// the file and removes them. Any other reader falls back to `legacy` on every
/// read, and its saves write only the key saved.
final class LauncherSettingsFile: LauncherSettingsStorage {
    static let schemaVersion = 1
    static let maximumBytes = 65_536
    static let vmSettingsFileName = "settings.json"
    static let storageLocationFileName = "storage-location.json"
    static let fullAppPreferencesDomain = "dev.tryomarchy.native"

    static let vmSettingKeys = [
        VMResourcePreferenceStore.key,
        MemoryPreferenceStore.key,
        VMNetworkPreferenceStore.key,
        PortForwardingPreferenceStore.key,
        SharedFolderPreferenceStore.key,
        USBDevicePreferenceStore.key,
        FullscreenPreferenceStore.key,
        DictationPreferenceStore.key,
    ]

    private enum Location {
        /// A file there before the launcher marks the folder would make a
        /// chosen empty folder look used.
        case workspace
        case folder
    }

    let fileName: String
    private let directory: () -> URL?
    private let location: Location
    private let legacy: UserDefaults?
    private let legacyIsWritable: Bool
    private let adoptsLegacy: () -> Bool
    private let legacyKeys: [String]

    private init(fileName: String, location: Location, legacy: UserDefaults?, legacyIsWritable: Bool,
                 adoptsLegacy: @escaping () -> Bool, legacyKeys: [String], directory: @escaping () -> URL?) {
        self.fileName = fileName
        self.location = location
        self.legacy = legacy
        self.legacyIsWritable = legacyIsWritable
        self.adoptsLegacy = adoptsLegacy
        self.legacyKeys = legacyKeys
        self.directory = directory
    }

    /// A scratch VM chosen by the environment must not take the person's
    /// settings, so `adoptsLegacy` is false for it.
    static func vmSettings(
        legacy: UserDefaults?,
        legacyIsWritable: Bool = true,
        adoptsLegacy: @escaping () -> Bool = { true },
        root: @escaping () -> URL?
    ) -> LauncherSettingsFile {
        LauncherSettingsFile(fileName: vmSettingsFileName, location: .workspace, legacy: legacy,
                             legacyIsWritable: legacyIsWritable, adoptsLegacy: adoptsLegacy,
                             legacyKeys: vmSettingKeys, directory: root)
    }

    /// Which folder holds the VM. It cannot live in the VM's folder, so it
    /// stays in the fixed `Try Omarchy` folder that every kit resolves.
    static func storageLocation(
        legacy: UserDefaults?,
        legacyIsWritable: Bool = true,
        directory: URL? = defaultStorageLocationDirectory()
    ) -> LauncherSettingsFile {
        LauncherSettingsFile(fileName: storageLocationFileName, location: .folder, legacy: legacy,
                             legacyIsWritable: legacyIsWritable, adoptsLegacy: { true },
                             legacyKeys: [StorageLocationPreferenceStore.key], directory: { directory })
    }

    static func defaultStorageLocationDirectory(fileManager: FileManager = .default) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(StorageLocationPolicy.workspaceDirectoryName, isDirectory: true)
    }

    /// Try Omarchy's own preferences, for an app running the kit under
    /// another identity. Read only: the full app moves them into the files.
    static func fullAppPreferences() -> UserDefaults {
        UserDefaults(suiteName: fullAppPreferencesDomain) ?? .standard
    }

    func settingData(forKey key: String) -> Data? {
        guard let folder = readyFolder(creating: movesLegacySettings) else { return legacyData(forKey: key) }
        if movesLegacySettings { try? withLock(folder) { try adoptLegacySettings(in: folder) } }
        let settings: [String: Any]
        switch try? contents(in: folder) {
        case .settings(_, let stored)?: settings = stored
        case .absent?, .unreadable?: settings = [:]
        case nil: return nil
        }
        guard let value = settings[key] else { return legacyData(forKey: key) }
        guard !(value is NSNull) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    }

    func setSettingData(_ data: Data, forKey key: String) throws {
        try update(key: key, value: JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    /// Kept as null rather than dropped, so a legacy value never comes back.
    func removeSetting(forKey key: String) throws {
        try update(key: key, value: NSNull())
    }

    var untrustedReason: String? {
        guard let folder = directory()?.standardizedFileURL else { return nil }
        var information = stat()
        guard lstat(folder.path, &information) == 0 else { return nil }
        guard let ready = readyFolder(creating: false) else {
            return location == .folder ? "\(folder.path) is not a private folder." : nil
        }
        do {
            if case .unreadable = try contents(in: ready), location == .folder {
                return "\(ready.appendingPathComponent(fileName).path) is damaged."
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func adoptLegacySettings() {
        guard movesLegacySettings, let folder = readyFolder(creating: true) else { return }
        try? withLock(folder) { try adoptLegacySettings(in: folder) }
    }

    private func legacyData(forKey key: String) -> Data? {
        adoptsLegacy() ? legacy?.data(forKey: key) : nil
    }

    private var movesLegacySettings: Bool {
        guard legacyIsWritable, let legacy, adoptsLegacy() else { return false }
        return legacyKeys.contains { legacy.object(forKey: $0) != nil }
    }

    private func update(key: String, value: Any) throws {
        guard let folder = readyFolder(creating: true) else {
            guard let legacy, legacyIsWritable, adoptsLegacy() else {
                fputs("[settings] The settings folder is unavailable; \(key) was not saved.\n", stderr)
                throw HelperError.io("The settings folder is unavailable.")
            }
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
               !(value is NSNull) {
                legacy.set(data, forKey: key)
            } else {
                legacy.removeObject(forKey: key)
            }
            return
        }
        do {
            try withLock(folder) {
                if movesLegacySettings { try adoptLegacySettings(in: folder) }
                var (object, settings) = try storedObject(in: folder)
                settings[key] = value
                object["settings"] = settings
                try write(object, in: folder)
            }
        } catch {
            fputs("[settings] \(key) was not saved: \(error.localizedDescription)\n", stderr)
            throw error
        }
    }

    /// Call with the folder locked.
    private func adoptLegacySettings(in folder: URL) throws {
        guard legacyIsWritable, let legacy, adoptsLegacy() else { return }
        var (object, settings) = try storedObject(in: folder)
        var adopted = false
        for key in legacyKeys where settings[key] == nil {
            guard let data = legacy.data(forKey: key),
                  let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            else { continue }
            settings[key] = value
            adopted = true
        }
        if adopted {
            object["settings"] = settings
            try write(object, in: folder)
        }
        for key in legacyKeys where settings[key] != nil { legacy.removeObject(forKey: key) }
    }

    private enum Contents {
        case absent
        /// Damaged content, which the next save replaces.
        case unreadable
        case settings(object: [String: Any], settings: [String: Any])
    }

    /// Throws for a file that must be neither read nor replaced.
    private func contents(in folder: URL) throws -> Contents {
        let url = folder.appendingPathComponent(fileName)
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            guard errno == ENOENT else { throw HelperError.io("\(url.path) could not be checked.") }
            return .absent
        }
        guard Self.isPrivate(information, type: S_IFREG, permissions: 0o600) else {
            throw HelperError.io("\(url.path) is not a private file.")
        }
        guard information.st_size <= Self.maximumBytes else { throw HelperError.io("\(url.path) is too large.") }
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              let settings = object["settings"] as? [String: Any]
        else { return .unreadable }
        guard version.doubleValue == Double(Self.schemaVersion) else {
            throw HelperError.io("\(url.path) was written by a newer version.")
        }
        return .settings(object: object, settings: settings)
    }

    private func storedObject(in folder: URL) throws -> (object: [String: Any], settings: [String: Any]) {
        switch try contents(in: folder) {
        case .absent, .unreadable: return ([:], [:])
        case .settings(let object, let settings): return (object, settings)
        }
    }

    /// The file is private from its first byte, so a crash never leaves a
    /// readable copy that later loads would refuse.
    private func write(_ object: [String: Any], in folder: URL) throws {
        var object = object
        object["schemaVersion"] = Self.schemaVersion
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard data.count <= Self.maximumBytes else { throw HelperError.io("\(fileName) would be too large.") }
        let temporary = folder.appendingPathComponent(".\(fileName).\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw HelperError.io("\(fileName) could not be created.") }
        var written = 0
        let complete = data.withUnsafeBytes { buffer -> Bool in
            while written < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress! + written, buffer.count - written)
                if count > 0 {
                    written += count
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        let saved = complete && fchmod(descriptor, 0o600) == 0 && fsync(descriptor) == 0
        close(descriptor)
        guard saved, rename(temporary.path, folder.appendingPathComponent(fileName).path) == 0 else {
            unlink(temporary.path)
            throw HelperError.io("\(fileName) could not be saved.")
        }
    }

    /// The full app and the run mode can both save while one runs the VM.
    private func withLock(_ folder: URL, _ body: () throws -> Void) throws {
        let descriptor = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw HelperError.io("\(folder.path) could not be opened.") }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw HelperError.io("\(folder.path) could not be locked.") }
        }
        try body()
    }

    private func readyFolder(creating: Bool) -> URL? {
        guard let folder = directory()?.standardizedFileURL else { return nil }
        var information = stat()
        switch location {
        case .workspace:
            guard StorageLocationPolicy.hasValidRootMarker(in: folder),
                  lstat(folder.path, &information) == 0,
                  Self.isPrivate(information, type: S_IFDIR, permissions: 0o700) else { return nil }
        case .folder:
            if lstat(folder.path, &information) != 0 {
                guard creating, errno == ENOENT,
                      (try? FileManager.default.createDirectory(
                        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])) != nil,
                      lstat(folder.path, &information) == 0 else { return nil }
            }
            guard information.st_mode & S_IFMT == S_IFDIR, information.st_uid == getuid(),
                  information.st_mode & 0o022 == 0 else { return nil }
        }
        return folder
    }

    private static func isPrivate(_ information: stat, type: mode_t, permissions: mode_t) -> Bool {
        information.st_mode & S_IFMT == type
            && information.st_uid == getuid()
            && information.st_mode & 0o777 == permissions
    }
}
