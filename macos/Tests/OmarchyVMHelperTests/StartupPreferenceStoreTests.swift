import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Automatic startup")
struct StartupPreferenceStoreTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omarchy-startup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return root
    }

    private func initializeWorkspace(_ root: URL) throws {
        let marker = root.appendingPathComponent(StorageLocationPolicy.rootMarkerName)
        try Data("\(StorageLocationPolicy.rootMarkerContent)\n".utf8).write(to: marker)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
    }

    private func writeSettings(_ contents: String, in root: URL) throws {
        let file = root.appendingPathComponent(StartupPreferenceStore.fileName)
        try Data(contents.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    @Test("Skip launcher is opt-in and persists only within its workspace")
    func savesChoice() throws {
        let root = try temporaryRoot()
        let other = try temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: other)
        }
        try initializeWorkspace(root)
        try initializeWorkspace(other)
        let store = StartupPreferenceStore()
        #expect(!store.load(storageRoot: root))
        #expect(!store.load(storageRoot: nil))

        try store.save(true, storageRoot: root)
        #expect(StartupPreferenceStore().load(storageRoot: root))
        #expect(!store.load(storageRoot: other))
        try store.save(false, storageRoot: root)
        #expect(!StartupPreferenceStore().load(storageRoot: root))
        try store.save(true, storageRoot: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent(StartupPreferenceStore.fileName))
        #expect(!store.load(storageRoot: root))
        try store.save(true, storageRoot: root)
        try FileManager.default.removeItem(at: root)
        #expect(!store.load(storageRoot: root))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try initializeWorkspace(root)
        #expect(!store.load(storageRoot: root))
    }

    @Test("A choice before first launch leaves an empty custom folder usable")
    func defersFirstChoice() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StartupPreferenceStore()
        try store.save(true, storageRoot: root)
        #expect(store.load(storageRoot: root))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        #expect(!StartupPreferenceStore().load(storageRoot: root))
        try initializeWorkspace(root)
        try store.persistPendingChoice(storageRoot: root)
        #expect(StartupPreferenceStore().load(storageRoot: root))
        try FileManager.default.removeItem(at: root.appendingPathComponent(StartupPreferenceStore.fileName))
        #expect(!store.load(storageRoot: root))
    }

    @Test("Missing, damaged and unsupported settings fail closed", arguments: [
        "", "broken", "{}", "{\"schemaVersion\":2,\"startAutomatically\":true}",
        "{\"schemaVersion\":1,\"startAutomatically\":\"true\"}", String(repeating: "x", count: 4097),
    ])
    func rejectsInvalidSettings(contents: String) throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try initializeWorkspace(root)
        try writeSettings(contents, in: root)
        #expect(!StartupPreferenceStore().load(storageRoot: root))
    }

    @Test("A settings symlink is neither read nor overwritten")
    func rejectsSymlink() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try initializeWorkspace(root)
        let target = root.appendingPathComponent("target")
        let contents = Data("{\"schemaVersion\":1,\"startAutomatically\":true}".utf8)
        try contents.write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let file = root.appendingPathComponent(StartupPreferenceStore.fileName)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let store = StartupPreferenceStore()
        #expect(!store.load(storageRoot: root))
        #expect(throws: HelperError.self) { try store.save(false, storageRoot: root) }
        #expect(try Data(contentsOf: target) == contents)
    }

    @Test("Workspace resolution follows a custom location and the environment override")
    func resolvesWorkspace() {
        let preference = StorageLocationPreference(containerPath: "/private/tmp/selected-vm")
        #expect(QEMUGPUStorageSpaceEstimate.storageRootURL(environment: [:], preference: preference)?.path
                == preference.containerPath)
        #expect(QEMUGPUStorageSpaceEstimate.storageRootURL(
            environment: [StorageLocationPolicy.environmentKey: "/private/tmp/override-vm"],
            preference: preference)?.path == "/private/tmp/override-vm")
        #expect(QEMUGPUStorageSpaceEstimate.storageRootURL(environment: [:])?.path
                == FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/Try Omarchy/VM/v1").path)
    }

    @Test("Only an existing VM with an enabled preference and no Option override skips the menu",
          arguments: [false, true], [false, true])
    func respectsPreferenceAndOverride(isEnabled: Bool, optionKeyHeld: Bool) {
        for hasExistingVM in [false, true] {
            #expect(StartupPolicy.shouldStartAutomatically(
                isEnabled: isEnabled,
                hasExistingVM: hasExistingVM,
                optionKeyHeld: optionKeyHeld,
                initialArguments: []
            ) == (isEnabled && hasExistingVM && !optionKeyHeld))
        }
    }

    @Test("A surviving settings file cannot skip the launcher after the disk is deleted")
    func deletedDiskShowsLauncher() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try initializeWorkspace(root)
        let diskDirectory = root.appendingPathComponent("disks/current")
        try FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let identity = String(repeating: "a", count: 64)
        let metadata = diskDirectory.appendingPathComponent("metadata.json")
        try Data("{\"bundleIdentity\":\"\(identity)\",\"kind\":\"omarchy-qemu-persistent-disk\",\"schemaVersion\":2,\"sourceRootfs\":{\"bytes\":1,\"sha256\":\"\(identity)\"}}\n".utf8).write(to: metadata)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
        let disk = diskDirectory.appendingPathComponent("rootfs.ext4")
        try Data([0]).write(to: disk)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: disk.path)
        let store = StartupPreferenceStore()
        try store.save(true, storageRoot: root)
        func shouldSkip() -> Bool {
            StartupPolicy.shouldStartAutomatically(
                isEnabled: store.load(storageRoot: root),
                hasExistingVM: QEMUGPUStorageSpaceEstimate.hasRecordedPersistentDisk(stateRoot: root.path),
                optionKeyHeld: false, initialArguments: [])
        }
        #expect(shouldSkip())
        try FileManager.default.removeItem(at: disk)
        #expect(store.load(storageRoot: root))
        #expect(!shouldSkip())
    }

    @Test("Explicit resets and disposable sessions always show the launcher",
          arguments: ["--reset-storage", "--reset-storage-only", "--ephemeral"])
    func freshLaunchShowsMenu(argument: String) {
        #expect(!StartupPolicy.shouldStartAutomatically(
            isEnabled: true,
            hasExistingVM: true,
            optionKeyHeld: false,
            initialArguments: [argument, "/guest"]
        ))
    }

    @Test("A custom guest launch with an existing VM honors automatic startup")
    func customGuest() {
        #expect(StartupPolicy.shouldStartAutomatically(
            isEnabled: true, hasExistingVM: true, optionKeyHeld: false, initialArguments: ["/guest"]))
    }
}
