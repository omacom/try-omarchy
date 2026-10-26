import Foundation
import Testing
@testable import OmarchyVMHelper

/// A temporary folder, and a UserDefaults suite standing in for the full
/// app's older preferences.
final class LauncherSettingsFixture {
    let root: URL
    let suiteName = "LauncherSettingsFileTests.\(UUID().uuidString)"
    let legacy: UserDefaults

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omarchy-settings-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        legacy = UserDefaults(suiteName: suiteName)!
        legacy.removePersistentDomain(forName: suiteName)
    }

    deinit {
        legacy.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    /// What run-qemu-gpu.sh leaves once it owns the folder.
    func markWorkspace() throws {
        let marker = root.appendingPathComponent(StorageLocationPolicy.rootMarkerName)
        try Data("\(StorageLocationPolicy.rootMarkerContent)\n".utf8).write(to: marker)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    }

    var settingsURL: URL { root.appendingPathComponent(LauncherSettingsFile.vmSettingsFileName) }

    func vmSettings(legacy: Bool = true, writable: Bool = true, adopts: Bool = true) -> LauncherSettingsFile {
        let root = root
        return LauncherSettingsFile.vmSettings(legacy: legacy ? self.legacy : nil, legacyIsWritable: writable,
                                               adoptsLegacy: { adopts }) { root }
    }

    func writeSettingsFile(_ contents: String, permissions: Int = 0o600) throws {
        try Data(contents.utf8).write(to: settingsURL)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: settingsURL.path)
    }

    func settingsFile() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
    }
}

@Suite("Launcher settings file")
struct LauncherSettingsFileTests {
    @Test("settings round-trip through a private, versioned file in the VM folder")
    func roundTrip() throws {
        let fixture = try LauncherSettingsFixture()
        try fixture.markWorkspace()
        let network = VMNetworkPreferences(mode: .bridged, interface: "en0", wifiCompatibility: false, bridgedSSH: true)
        try VMNetworkPreferenceStore(storage: fixture.vmSettings(legacy: false)).save(network)
        FullscreenPreferenceStore(storage: fixture.vmSettings(legacy: false))
            .save(FullscreenPreferences(isImmersive: false, usesNotch: false))
        try PortForwardingPreferenceStore(storage: fixture.vmSettings(legacy: false)).save([PortForwardPreset.ssh])
        VMResourcePreferenceStore(storage: fixture.vmSettings(legacy: false))
            .save(VMResources(cpuCount: 6, memoryGiB: 8, diskGiB: 96))

        let reopened = fixture.vmSettings(legacy: false)
        #expect(VMNetworkPreferenceStore(storage: reopened).load() == network)
        #expect(FullscreenPreferenceStore(storage: reopened).load() == FullscreenPreferences(isImmersive: false, usesNotch: false))
        #expect(PortForwardingPreferenceStore(storage: reopened).load() == [PortForwardPreset.ssh])
        #expect(VMResourcePreferenceStore(storage: reopened).load() == VMResources(cpuCount: 6, memoryGiB: 8, diskGiB: 96))

        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.settingsURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let file = try fixture.settingsFile()
        #expect(file["schemaVersion"] as? Int == 1)
        let settings = try #require(file["settings"] as? [String: Any])
        #expect(Set(settings.keys) == [VMNetworkPreferenceStore.key, FullscreenPreferenceStore.key,
                                       PortForwardingPreferenceStore.key, VMResourcePreferenceStore.key])

        VMResourcePreferenceStore(storage: reopened).clear()
        #expect(VMResourcePreferenceStore(storage: fixture.vmSettings(legacy: false)).load() == nil)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
            .filter { $0.hasPrefix(".\(LauncherSettingsFile.vmSettingsFileName)") }
        #expect(leftovers.isEmpty)
    }

    @Test("concurrent saves from two apps keep every value")
    func concurrentSaves() throws {
        let fixture = try LauncherSettingsFixture()
        try fixture.markWorkspace()
        let root = fixture.root
        DispatchQueue.concurrentPerform(iterations: 2) { writer in
            let file = LauncherSettingsFile.vmSettings(legacy: nil) { root }
            for index in 0..<25 {
                try? file.setSettingData(Data("\(index)".utf8), forKey: "writer\(writer)-\(index)")
            }
        }
        let settings = try #require(fixture.settingsFile()["settings"] as? [String: Any])
        #expect(settings.count == 50)
    }

    @Test("a newer kit's keys survive an older kit's save")
    func keepsUnknownKeys() throws {
        let fixture = try LauncherSettingsFixture()
        try fixture.markWorkspace()
        try fixture.writeSettingsFile(#"{"future":1,"schemaVersion":1,"settings":{"futureSetting":{"on":true}}}"#)
        FullscreenPreferenceStore(storage: fixture.vmSettings()).save(.defaults)
        #expect(try fixture.settingsFile()["future"] as? Int == 1)
        let settings = try #require(fixture.settingsFile()["settings"] as? [String: Any])
        #expect(settings["futureSetting"] != nil)
        #expect(settings[FullscreenPreferenceStore.key] != nil)
    }

    @Test("an unmarked folder gets no file, so a chosen empty folder stays usable")
    func waitsForTheWorkspace() throws {
        let fixture = try LauncherSettingsFixture()
        let pending = SharedFolderPreference(path: "/Users/someone/Shared", isEnabled: true)
        SharedFolderPreferenceStore(storage: fixture.vmSettings()).save(pending)
        #expect(!FileManager.default.fileExists(atPath: fixture.settingsURL.path))
        #expect(fixture.legacy.data(forKey: SharedFolderPreferenceStore.key) != nil)
        #expect(SharedFolderPreferenceStore(storage: fixture.vmSettings()).load() == pending)

        SharedFolderPreferenceStore(storage: fixture.vmSettings(legacy: false)).save(.disabled)
        #expect(!FileManager.default.fileExists(atPath: fixture.settingsURL.path))
        #expect(SharedFolderPreferenceStore(storage: fixture.vmSettings(legacy: false)).load() == .disabled)

        try fixture.markWorkspace()
        #expect(SharedFolderPreferenceStore(storage: fixture.vmSettings(legacy: false)).load() == .disabled)
        fixture.vmSettings().adoptLegacySettings()
        #expect(SharedFolderPreferenceStore(storage: fixture.vmSettings(legacy: false)).load() == pending)
        #expect(fixture.legacy.data(forKey: SharedFolderPreferenceStore.key) == nil)
    }

    @Test("the full app's UserDefaults move into the file once")
    func migratesOnce() throws {
        let fixture = try LauncherSettingsFixture()
        try fixture.markWorkspace()
        let old = VMNetworkPreferences(mode: .bridged, interface: "en1")
        try VMNetworkPreferenceStore(defaults: fixture.legacy).save(old)
        MemoryPreferenceStore(defaults: fixture.legacy).save(MemoryPreferences(memoryMiB: 12_288))
        try PortForwardingPreferenceStore(defaults: fixture.legacy).save([PortForwardPreset.ssh])
        fixture.legacy.set(Data("kept".utf8), forKey: "audioRoutingPreferences")

        #expect(VMNetworkPreferenceStore(storage: fixture.vmSettings()).load() == old)
        #expect(VMResourcePreferenceStore(storage: fixture.vmSettings()).load()?.memoryGiB == 12)
        #expect(fixture.legacy.data(forKey: VMNetworkPreferenceStore.key) == nil)
        #expect(fixture.legacy.data(forKey: MemoryPreferenceStore.key) == nil)
        #expect(fixture.legacy.data(forKey: "audioRoutingPreferences") != nil)
        #expect(PortForwardingPreferenceStore(storage: fixture.vmSettings(legacy: false)).load() == [PortForwardPreset.ssh])

        try VMNetworkPreferenceStore(defaults: fixture.legacy).save(VMNetworkPreferences(mode: .bridged, interface: "en9"))
        #expect(VMNetworkPreferenceStore(storage: fixture.vmSettings()).load() == old)
        #expect(fixture.legacy.data(forKey: VMNetworkPreferenceStore.key) == nil)
    }

    @Test("the full app still moves its settings after the run mode wrote the file first")
    func migratesAfterTheRunModeWrote() throws {
        let fixture = try LauncherSettingsFixture()
        try fixture.markWorkspace()
        let shared = SharedFolderPreference(path: "/Users/someone/Shared", isEnabled: true)
        SharedFolderPreferenceStore(defaults: fixture.legacy).save(shared)
        try PortForwardingPreferenceStore(defaults: fixture.legacy).save([PortForwardPreset.ssh])
        FullscreenPreferenceStore(defaults: fixture.legacy).save(.defaults)

        let immersiveOff = FullscreenPreferences(isImmersive: false, usesNotch: true)
        FullscreenPreferenceStore(storage: fixture.vmSettings(legacy: false)).save(immersiveOff)
        #expect(FileManager.default.fileExists(atPath: fixture.settingsURL.path))

        let fullApp = fixture.vmSettings()
        #expect(SharedFolderPreferenceStore(storage: fullApp).load() == shared)
        #expect(PortForwardingPreferenceStore(storage: fullApp).load() == [PortForwardPreset.ssh])
        #expect(FullscreenPreferenceStore(storage: fullApp).load() == immersiveOff)
        for key in [SharedFolderPreferenceStore.key, PortForwardingPreferenceStore.key, FullscreenPreferenceStore.key] {
            #expect(fixture.legacy.data(forKey: key) == nil, "\(key)")
        }
    }

    @Test("the run mode reads the full app's settings without changing them, and a reset stays reset")
    func readsTheFullAppsSettings() throws {
        let fixture = try LauncherSettingsFixture()
        try fixture.markWorkspace()
        VMResourcePreferenceStore(defaults: fixture.legacy).save(VMResources(cpuCount: 6, memoryGiB: 8))
        let runMode = fixture.vmSettings(writable: false)
        #expect(VMResourcePreferenceStore(storage: runMode).load() == VMResources(cpuCount: 6, memoryGiB: 8))
        #expect(fixture.legacy.data(forKey: VMResourcePreferenceStore.key) != nil)

        VMResourcePreferenceStore(storage: runMode).clear()
        #expect(VMResourcePreferenceStore(storage: fixture.vmSettings(writable: false)).load() == nil)
        #expect(VMResourcePreferenceStore(storage: fixture.vmSettings()).load() == nil)
        #expect(fixture.legacy.data(forKey: VMResourcePreferenceStore.key) == nil)
    }

    @Test("1.2 changes after the run mode read reach the run mode's next start")
    func runModeFollowsLaterLegacyChanges() throws {
        let fixture = try LauncherSettingsFixture()
        try fixture.markWorkspace()
        let folder = fixture.root.appendingPathComponent("Try Omarchy", isDirectory: true)
        let pointer = {
            StorageLocationPreferenceStore(storage: LauncherSettingsFile.storageLocation(
                legacy: fixture.legacy, legacyIsWritable: false, directory: folder))
        }
        VMResourcePreferenceStore(defaults: fixture.legacy).save(VMResources(cpuCount: 4, memoryGiB: 8))
        try StorageLocationPreferenceStore(defaults: fixture.legacy)
            .save(StorageLocationPreference(containerPath: "/Volumes/Old/Omarchy"))
        #expect(VMResourcePreferenceStore(storage: fixture.vmSettings(writable: false)).load()?.memoryGiB == 8)
        #expect(pointer().load().containerPath == "/Volumes/Old/Omarchy")

        VMResourcePreferenceStore(defaults: fixture.legacy).save(VMResources(cpuCount: 4, memoryGiB: 12))
        try StorageLocationPreferenceStore(defaults: fixture.legacy)
            .save(StorageLocationPreference(containerPath: "/Volumes/New/Omarchy"))
        #expect(VMResourcePreferenceStore(storage: fixture.vmSettings(writable: false)).load()?.memoryGiB == 12)
        #expect(pointer().load().containerPath == "/Volumes/New/Omarchy")

        try StorageLocationPreferenceStore(defaults: fixture.legacy).save(.default)
        #expect(pointer().load() == .default)
        #expect(pointer().problem() == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.settingsURL.path))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(fixture.legacy.data(forKey: VMResourcePreferenceStore.key) != nil)
    }

    @Test("run mode writes first, then 1.2 changes, then the full app migrates: saved keys keep the run mode's values")
    func runModeWritesThenLegacyChangesThenFullAppMigrates() throws {
        let fixture = try LauncherSettingsFixture()
        try fixture.markWorkspace()
        let shared = SharedFolderPreference(path: "/Users/someone/Shared", isEnabled: true)
        SharedFolderPreferenceStore(defaults: fixture.legacy).save(shared)
        FullscreenPreferenceStore(defaults: fixture.legacy).save(.defaults)
        VMResourcePreferenceStore(defaults: fixture.legacy).save(VMResources(cpuCount: 4, memoryGiB: 8))

        let immersiveOff = FullscreenPreferences(isImmersive: false, usesNotch: true)
        FullscreenPreferenceStore(storage: fixture.vmSettings(writable: false)).save(immersiveOff)
        let written = try #require(fixture.settingsFile()["settings"] as? [String: Any])
        #expect(Set(written.keys) == [FullscreenPreferenceStore.key])

        FullscreenPreferenceStore(defaults: fixture.legacy).save(FullscreenPreferences(isImmersive: true, usesNotch: false))
        VMResourcePreferenceStore(defaults: fixture.legacy).save(VMResources(cpuCount: 6, memoryGiB: 16))
        let runMode = fixture.vmSettings(writable: false)
        #expect(FullscreenPreferenceStore(storage: runMode).load() == immersiveOff)
        #expect(VMResourcePreferenceStore(storage: runMode).load() == VMResources(cpuCount: 6, memoryGiB: 16))

        let fullApp = fixture.vmSettings()
        #expect(FullscreenPreferenceStore(storage: fullApp).load() == immersiveOff)
        #expect(VMResourcePreferenceStore(storage: fullApp).load() == VMResources(cpuCount: 6, memoryGiB: 16))
        #expect(SharedFolderPreferenceStore(storage: fullApp).load() == shared)
        for key in [SharedFolderPreferenceStore.key, FullscreenPreferenceStore.key, VMResourcePreferenceStore.key] {
            #expect(fixture.legacy.data(forKey: key) == nil, "\(key)")
        }

        VMResourcePreferenceStore(defaults: fixture.legacy).save(VMResources(cpuCount: 2, memoryGiB: 4))
        #expect(VMResourcePreferenceStore(storage: fixture.vmSettings(writable: false)).load()
                == VMResources(cpuCount: 6, memoryGiB: 16))
        #expect(VMResourcePreferenceStore(storage: fixture.vmSettings()).load() == VMResources(cpuCount: 6, memoryGiB: 16))
    }

    @Test("the settings window under the installer writes, then 1.2 changes: the window's values win")
    func settingsWindowWritesThenLegacyChanges() throws {
        let fixture = try LauncherSettingsFixture()
        try fixture.markWorkspace()
        try VMNetworkPreferenceStore(defaults: fixture.legacy).save(VMNetworkPreferences(mode: .bridged, interface: "en0"))
        VMResourcePreferenceStore(defaults: fixture.legacy).save(VMResources(cpuCount: 4, memoryGiB: 8))

        let window = fixture.vmSettings(writable: false)
        let shared = VMNetworkPreferences()
        try VMNetworkPreferenceStore(storage: window).save(shared)
        VMResourcePreferenceStore(storage: window).clear()

        try VMNetworkPreferenceStore(defaults: fixture.legacy).save(VMNetworkPreferences(mode: .bridged, interface: "en1"))
        VMResourcePreferenceStore(defaults: fixture.legacy).save(VMResources(cpuCount: 6, memoryGiB: 16))
        MemoryPreferenceStore(defaults: fixture.legacy).save(MemoryPreferences(memoryMiB: 12_288))

        for reader in [fixture.vmSettings(writable: false), fixture.vmSettings()] {
            #expect(VMNetworkPreferenceStore(storage: reader).load() == shared)
            #expect(VMResourcePreferenceStore(storage: reader).load() == nil)
        }
        #expect(fixture.legacy.data(forKey: VMNetworkPreferenceStore.key) == nil)
    }

    @Test("a VM chosen by the environment never takes the person's settings")
    func scratchVMsDoNotAdopt() throws {
        let fixture = try LauncherSettingsFixture()
        let network = VMNetworkPreferences(mode: .bridged, interface: "en1")
        try VMNetworkPreferenceStore(defaults: fixture.legacy).save(network)
        let scratch = fixture.vmSettings(adopts: false)
        #expect(VMNetworkPreferenceStore(storage: scratch).load() == VMNetworkPreferences())
        FullscreenPreferenceStore(storage: scratch).save(FullscreenPreferences(isImmersive: false))
        #expect(fixture.legacy.data(forKey: FullscreenPreferenceStore.key) == nil)

        try fixture.markWorkspace()
        #expect(VMNetworkPreferenceStore(storage: scratch).load() == VMNetworkPreferences())
        FullscreenPreferenceStore(storage: scratch).save(.defaults)
        #expect(fixture.legacy.data(forKey: VMNetworkPreferenceStore.key) != nil)
        let settings = try #require(fixture.settingsFile()["settings"] as? [String: Any])
        #expect(settings[VMNetworkPreferenceStore.key] == nil)
    }

    @Test("files that are not private, damaged, too large or newer are not trusted")
    func rejectsBadFiles() throws {
        let fixture = try LauncherSettingsFixture()
        try fixture.markWorkspace()
        let valid = #"{"schemaVersion":1,"settings":{"fullscreenPreferences":{"schemaVersion":1,"isImmersive":false}}}"#
        let store = { FullscreenPreferenceStore(storage: fixture.vmSettings(legacy: false)) }

        try fixture.writeSettingsFile(valid)
        #expect(store().load().isImmersive == false)

        try fixture.writeSettingsFile(valid, permissions: 0o644)
        #expect(store().load() == .defaults)
        store().save(FullscreenPreferences(isImmersive: true, usesNotch: false))
        #expect(try String(contentsOf: fixture.settingsURL, encoding: .utf8) == valid)

        try fixture.writeSettingsFile(valid.replacingOccurrences(of: #""schemaVersion":1,"settings""#,
                                                                 with: #""schemaVersion":2,"settings""#))
        #expect(store().load() == .defaults)
        store().save(.defaults)
        #expect(try fixture.settingsFile()["schemaVersion"] as? Int == 2)

        try fixture.writeSettingsFile(#"{"schemaVersion":true,"settings":{}}"#)
        #expect(store().load() == .defaults)

        try fixture.writeSettingsFile(String(repeating: " ", count: LauncherSettingsFile.maximumBytes) + valid)
        #expect(store().load() == .defaults)

        try fixture.writeSettingsFile("not json")
        #expect(store().load() == .defaults)
        store().save(FullscreenPreferences(isImmersive: false, usesNotch: true))
        #expect(store().load() == FullscreenPreferences(isImmersive: false, usesNotch: true))

        try FileManager.default.removeItem(at: fixture.settingsURL)
        let elsewhere = fixture.root.appendingPathComponent("elsewhere.json")
        try Data(valid.utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: fixture.settingsURL, withDestinationURL: elsewhere)
        #expect(store().load() == .defaults)

        try FileManager.default.removeItem(at: fixture.settingsURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.root.path)
        store().save(.defaults)
        #expect(!FileManager.default.fileExists(atPath: fixture.settingsURL.path))
    }

    @Test("the VM folder choice lives in its own file outside any VM folder")
    func storageLocationPointer() throws {
        let fixture = try LauncherSettingsFixture()
        let folder = fixture.root.appendingPathComponent("Try Omarchy", isDirectory: true)
        let pointer = folder.appendingPathComponent(LauncherSettingsFile.storageLocationFileName)
        let store = {
            StorageLocationPreferenceStore(storage: LauncherSettingsFile.storageLocation(legacy: nil, directory: folder))
        }
        #expect(store().load() == .default)
        try store().save(StorageLocationPreference(containerPath: "/Volumes/Drive/Omarchy"))
        #expect(store().load() == StorageLocationPreference(containerPath: "/Volumes/Drive/Omarchy"))
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(FileManager.default.fileExists(atPath: pointer.path))

        #expect(store().problem() == nil)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: pointer.path)
        #expect(store().problem() != nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pointer.path)
        try Data(#"{"schemaVersion":2,"settings":{}}"#.utf8).write(to: pointer)
        #expect(store().problem() != nil)
        try Data("damaged".utf8).write(to: pointer)
        #expect(store().problem() != nil)
        try Data(#"{"schemaVersion":1,"settings":{"storageLocationPreferences":{"schemaVersion":9}}}"#.utf8)
            .write(to: pointer)
        #expect(store().problem() != nil)

        try FileManager.default.removeItem(at: pointer)
        #expect(store().problem() == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: folder.path)
        #expect(store().load() == .default)
        #expect(store().problem() != nil)
    }

    @Test("a VM folder choice that cannot be saved fails, so a move never looks complete")
    func storageLocationSaveFailureThrows() throws {
        let fixture = try LauncherSettingsFixture()
        let folder = fixture.root.appendingPathComponent("Try Omarchy", isDirectory: true)
        let store = StorageLocationPreferenceStore(
            storage: LauncherSettingsFile.storageLocation(legacy: nil, directory: folder))
        try store.save(StorageLocationPreference(containerPath: "/Volumes/Old/Omarchy"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }

        #expect(throws: HelperError.self) {
            try store.save(StorageLocationPreference(containerPath: "/Volumes/New/Omarchy"))
        }
        #expect(store.load() == StorageLocationPreference(containerPath: "/Volumes/Old/Omarchy"))
    }

    @Test("the full app's VM folder choice moves into the pointer file, creating its folder")
    func migratesStorageLocation() throws {
        let fixture = try LauncherSettingsFixture()
        let folder = fixture.root.appendingPathComponent("Try Omarchy", isDirectory: true)
        try StorageLocationPreferenceStore(defaults: fixture.legacy)
            .save(StorageLocationPreference(containerPath: "/Volumes/Drive/Omarchy"))
        let migrated = StorageLocationPreferenceStore(
            storage: LauncherSettingsFile.storageLocation(legacy: fixture.legacy, directory: folder)
        ).load()
        #expect(migrated == StorageLocationPreference(containerPath: "/Volumes/Drive/Omarchy"))
        #expect(fixture.legacy.data(forKey: StorageLocationPreferenceStore.key) == nil)
        #expect(StorageLocationPreferenceStore(
            storage: LauncherSettingsFile.storageLocation(legacy: nil, directory: folder)
        ).load() == migrated)
    }

    @Test("the run mode finds a VM folder chosen in a full app that has not moved it yet")
    func runModeReadsTheFullAppsStorageLocation() throws {
        let fixture = try LauncherSettingsFixture()
        let folder = fixture.root.appendingPathComponent("Try Omarchy", isDirectory: true)
        let chosen = StorageLocationPreference(containerPath: "/Volumes/Drive/Omarchy")
        try StorageLocationPreferenceStore(defaults: fixture.legacy).save(chosen)
        let runMode = StorageLocationPreferenceStore(storage: LauncherSettingsFile.storageLocation(
            legacy: fixture.legacy, legacyIsWritable: false, directory: folder))
        #expect(runMode.load() == chosen)
        #expect(runMode.problem() == nil)
        #expect(fixture.legacy.data(forKey: StorageLocationPreferenceStore.key) != nil)
    }
}
