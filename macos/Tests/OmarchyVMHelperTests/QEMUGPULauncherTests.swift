import Darwin
import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("QEMU GPU app launch request")
struct QEMUGPULaunchRequestTests {
    @Test("accepts only the launcher storage flags and an optional absolute guest directory")
    func parsesAllowedArguments() {
        let guest = "/private/tmp/omarchy guest"
        #expect(QEMUGPULaunchRequest(arguments: []) == QEMUGPULaunchRequest(
            storageOption: nil,
            guestDirectoryPath: nil
        ))
        #expect(QEMUGPULaunchRequest(arguments: ["--ephemeral"]) == QEMUGPULaunchRequest(
            storageOption: .ephemeral,
            guestDirectoryPath: nil
        ))
        #expect(QEMUGPULaunchRequest(arguments: ["--reset-storage", guest]) == QEMUGPULaunchRequest(
            storageOption: .resetStorage,
            guestDirectoryPath: guest
        ))
        #expect(QEMUGPULaunchRequest(arguments: ["--reset-storage-only", guest]) == QEMUGPULaunchRequest(
            storageOption: .resetStorageOnly,
            guestDirectoryPath: guest
        ))
        #expect(QEMUGPULaunchRequest(arguments: [guest]) == QEMUGPULaunchRequest(
            storageOption: nil,
            guestDirectoryPath: guest
        ))
    }

    @Test("rejects unknown flags, relative paths, reordered flags, and extra arguments")
    func rejectsUnsafeArguments() {
        for arguments in [
            ["--unknown"],
            ["relative/guest"],
            ["/guest", "--ephemeral"],
            ["--ephemeral", "--reset-storage"],
            ["--ephemeral", "/guest", "/other"],
            ["/guest\nother"],
        ] {
            #expect(QEMUGPULaunchRequest(arguments: arguments) == nil)
        }
    }

    @Test("canonicalizes a safe guest directory before passing it to the script")
    func validatesGuestDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omarchy-qemu-request-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let request = try #require(QEMUGPULaunchRequest(arguments: ["--ephemeral", root.path]))
        #expect(try request.validatedScriptArguments() == ["--ephemeral", root.resolvingSymlinksInPath().path])
    }

    @Test("rejects a final guest-directory symlink")
    func rejectsGuestSymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omarchy-qemu-request-\(UUID().uuidString)", isDirectory: true)
        let guest = root.appendingPathComponent("guest", isDirectory: true)
        let link = root.appendingPathComponent("guest-link", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: guest, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: guest)

        let request = try #require(QEMUGPULaunchRequest(arguments: [link.path]))
        #expect(throws: HelperError.self) {
            try request.validatedScriptArguments()
        }
    }

}

@Suite("QEMU runtime environment")
struct QEMUGPURuntimeEnvironmentTests {
    @Test("ordinary launches strip build-only controls")
    func sanitizesLaunch() {
        let environment = QEMUGPURuntimeEnvironment.sanitizedForLaunch([
            "KEEP_ME": "yes",
            QEMUGPURuntimeEnvironment.inspectOnlyKey: "1",
            QEMUGPURuntimeEnvironment.dryRunKey: "1",
            QEMUGPURuntimeEnvironment.factoryCacheKey: "/private/tmp/inherited",
        ])

        #expect(environment == ["KEEP_ME": "yes"])
    }

    @Test("storage reset ignores inherited integration settings")
    func sanitizesReset() {
        let controlledKeys = [
            AudioLaunchConfiguration.inheritedSDLDeviceNameKey,
            AudioLaunchConfiguration.outputDeviceNameKey,
            AudioLaunchConfiguration.inputDeviceNameKey,
            SharedFolderPolicy.environmentKey,
            PortForwardPolicy.environmentKey,
            VMResourceLaunchConfiguration.cpuEnvironmentKey,
            VMResourceLaunchConfiguration.memoryEnvironmentKey,
            VMResourceLaunchConfiguration.diskEnvironmentKey,
            QEMUGPURuntimeEnvironment.inspectOnlyKey,
            QEMUGPURuntimeEnvironment.dryRunKey,
            QEMUGPURuntimeEnvironment.factoryCacheKey,
        ]
        var inherited = ["KEEP_ME": "yes"]
        for key in controlledKeys {
            inherited[key] = "untrusted inherited value"
        }

        #expect(QEMUGPURuntimeEnvironment.sanitizedForReset(inherited)
            == ["KEEP_ME": "yes"])
    }
}

@Suite("QEMU standard-error drain")
struct QEMUStandardErrorDrainTests {
    @Test("drains a bounded tail without waiting for EOF and restores descriptor flags")
    func boundedNonblockingDrain() throws {
        let pipe = Pipe()
        defer {
            pipe.fileHandleForReading.closeFile()
            pipe.fileHandleForWriting.closeFile()
        }

        let payload = Data("trailing QEMU diagnostic".utf8)
        try pipe.fileHandleForWriting.write(contentsOf: payload)
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let originalFlags = Darwin.fcntl(descriptor, F_GETFL)
        #expect(originalFlags >= 0)

        let first = QEMUGPUProcessSupervisor.drainAvailableStandardError(
            from: pipe.fileHandleForReading,
            maximumBytes: 8
        )
        #expect(first.data == Data(payload.prefix(8)))
        #expect(!first.reachedEnd)
        #expect(Darwin.fcntl(descriptor, F_GETFL) == originalFlags)

        let second = QEMUGPUProcessSupervisor.drainAvailableStandardError(
            from: pipe.fileHandleForReading,
            maximumBytes: 1_024
        )
        #expect(second.data == Data(payload.dropFirst(8)))
        #expect(!second.reachedEnd)
        #expect(Darwin.fcntl(descriptor, F_GETFL) == originalFlags)
    }

    @Test("reports EOF on a shut-down stream and restores descriptor flags")
    func drainAtEndOfStream() throws {
        var descriptors: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let reader = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        defer {
            reader.closeFile()
            Darwin.close(descriptors[1])
        }
        let descriptor = reader.fileDescriptor
        let originalFlags = Darwin.fcntl(descriptor, F_GETFL)
        #expect(originalFlags >= 0)

        // Parallel process tests can inherit a pipe writer and delay EOF after
        // close. Socket shutdown ends the stream even with inherited copies.
        try #require(Darwin.shutdown(descriptors[1], SHUT_WR) == 0)
        let end = QEMUGPUProcessSupervisor.drainAvailableStandardError(
            from: reader,
            maximumBytes: 1_024
        )
        #expect(end.data.isEmpty)
        #expect(end.reachedEnd)
        #expect(Darwin.fcntl(descriptor, F_GETFL) == originalFlags)
    }

    @Test("waits for a complete Ready line and carries its private QMP socket")
    func parsesReadyControlSocket() {
        let partial = "startup output\n[qemu-gpu] Ready. QMP: /tmp/omarchy-qemu-gpu.A1b2C3/qmp"
        #expect(QEMUGPUProcessSupervisor.virtualMachineReadyEvent(in: partial) == nil)

        let complete = partial + ".sock\nmore output\n"
        #expect(QEMUGPUProcessSupervisor.virtualMachineReadyEvent(in: complete) ==
            .virtualMachineReady(
                qmpSocketPath: "/tmp/omarchy-qemu-gpu.A1b2C3/qmp.sock"
            ))
    }

    @Test("ignores a Ready marker embedded inside another diagnostic line")
    func readyMarkerMustStartItsLine() {
        let output = """
            shared folder: /tmp/[qemu-gpu] Ready. QMP: not-a-socket
            [qemu-gpu] Ready. QMP: /tmp/omarchy-qemu-gpu.Z9y8X7/qmp.sock
            """ + "\n"
        #expect(QEMUGPUProcessSupervisor.virtualMachineReadyEvent(in: output) ==
            .virtualMachineReady(
                qmpSocketPath: "/tmp/omarchy-qemu-gpu.Z9y8X7/qmp.sock"
            ))

        let lookalike = "[qemu-gpu] Ready.bad QMP: /tmp/omarchy-qemu-gpu.Z9y8X7/qmp.sock\n"
        #expect(QEMUGPUProcessSupervisor.virtualMachineReadyEvent(in: lookalike) == nil)
    }

    @Test("does not trust a malformed socket advertised by the launcher")
    func rejectsMalformedReadyControlSocket() {
        for path in [
            "/tmp/omarchy-qemu-gpu.short/qmp.sock",
            "/tmp/omarchy-qemu-gpu.A1b2C3/../qmp.sock",
            "/private/tmp/omarchy-qemu-gpu.A1b2C3/qmp.sock",
            "/tmp/other.A1b2C3/qmp.sock",
        ] {
            let output = "[qemu-gpu] Ready. QMP: \(path)\n"
            #expect(QEMUGPUProcessSupervisor.virtualMachineReadyEvent(in: output) ==
                .virtualMachineReady(qmpSocketPath: nil))
        }
    }
}

@Suite("QEMU storage-space estimate")
struct QEMUGPUStorageSpaceEstimateTests {
    @Test("shows the app data folder while keeping the VM layout versioned")
    func displaysStorageRoot() throws {
        let configuredRoot = "/private/tmp/try-omarchy-configured/../data"
        let configuredEnvironment = ["OMARCHY_QEMU_GPU_STATE_ROOT": configuredRoot]
        let standardizedConfiguredRoot = URL(
            fileURLWithPath: configuredRoot,
            isDirectory: true
        ).standardizedFileURL
        #expect(QEMUGPUStorageSpaceEstimate.dataDirectoryDisplayPath(
            environment: configuredEnvironment
        ) == "/private/tmp/data")
        #expect(QEMUGPUStorageSpaceEstimate.dataDirectoryURL(
            environment: configuredEnvironment
        ) == standardizedConfiguredRoot)
        #expect(QEMUGPUStorageSpaceEstimate.storageRootURL(
            environment: configuredEnvironment
        ) == standardizedConfiguredRoot)

        let defaultDirectory = try #require(QEMUGPUStorageSpaceEstimate.dataDirectoryDisplayPath(
            environment: [:]
        ))
        #expect(defaultDirectory == "~/Library/Application Support/Try Omarchy")

        let defaultDirectoryURL = try #require(QEMUGPUStorageSpaceEstimate.dataDirectoryURL(
            environment: [:]
        ))
        let defaultStorageRoot = try #require(QEMUGPUStorageSpaceEstimate.storageRootURL(
            environment: [:]
        ))
        #expect(defaultStorageRoot == defaultDirectoryURL
            .appendingPathComponent("VM/v1", isDirectory: true)
            .standardizedFileURL)

        for invalidRoot in ["relative/path", "/private/tmp/..", "/tmp", "/bad\npath"] {
            let invalidEnvironment = ["OMARCHY_QEMU_GPU_STATE_ROOT": invalidRoot]
            #expect(QEMUGPUStorageSpaceEstimate.dataDirectoryURL(
                environment: invalidEnvironment
            ) == nil)
            #expect(QEMUGPUStorageSpaceEstimate.storageRootURL(
                environment: invalidEnvironment
            ) == nil)
        }
    }

    @Test("a chosen data folder replaces the default without the versioned suffix")
    func honorsStoredPreference() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("omarchy-launcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let preference = StorageLocationPreference(containerPath: container.path)

        // A chosen workspace is the state root itself, exactly as the launcher
        // script treats OMARCHY_QEMU_GPU_STATE_ROOT — the picked folder is
        // used directly, with no folder nested inside it.
        let expected = URL(fileURLWithPath: container.path, isDirectory: true)
            .standardizedFileURL
        #expect(QEMUGPUStorageSpaceEstimate.dataDirectoryURL(
            environment: [:],
            preference: preference
        ) == expected)
        #expect(QEMUGPUStorageSpaceEstimate.storageRootURL(
            environment: [:],
            preference: preference
        ) == expected)
    }

    @Test("the development override still wins over a stored preference")
    func overrideBeatsPreference() {
        let configured = "/private/tmp/try-omarchy-override"
        let expected = URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
        #expect(QEMUGPUStorageSpaceEstimate.storageRootURL(
            environment: ["OMARCHY_QEMU_GPU_STATE_ROOT": configured],
            preference: StorageLocationPreference(containerPath: "/Volumes/Ignored")
        ) == expected)
    }

    @Test("formats allocated bytes as a readable decimal gigabyte estimate")
    func formatsGigabytes() {
        #expect(QEMUGPUStorageSpaceEstimate.format(bytes: 0) == nil)
        #expect(QEMUGPUStorageSpaceEstimate.format(bytes: 50_000_000) == "less than 0.1 GB")
        #expect(QEMUGPUStorageSpaceEstimate.format(bytes: 3_250_000_000) == "3.2 GB")
    }

    @Test("a reset reclaims the VM's disk and UEFI variables, not the factory copy")
    func countsTheVM() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "try-omarchy-space-estimate-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        let environment = ["OMARCHY_QEMU_GPU_STATE_ROOT": root.path]
        #expect(QEMUGPUStorageSpaceEstimate.reclaimableBytes(environment: environment, fileManager: fileManager) == nil)

        let shell = root.appendingPathComponent("shell", isDirectory: true)
        let cache = root.appendingPathComponent("shell-factory", isDirectory: true)
        try fileManager.createDirectory(at: shell, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
        let disk = shell.appendingPathComponent("disk.img")
        let vars = shell.appendingPathComponent("efi-vars.fd")
        try Data(repeating: 0x5a, count: 16_384).write(to: disk)
        try Data(repeating: 0x5a, count: 8_192).write(to: vars)
        try Data(repeating: 0x5a, count: 65_536).write(to: cache.appendingPathComponent("factory.img"))
        #expect(Darwin.chmod(disk.path, 0o600) == 0)
        let expected = try #require(allocatedSize(of: disk)) + (try #require(allocatedSize(of: vars)))
        #expect(QEMUGPUStorageSpaceEstimate.reclaimableBytes(environment: environment, fileManager: fileManager) == expected)
        #expect(QEMUGPUStorageSpaceEstimate.hasRecordedPersistentDisk(stateRoot: root.path))

        // The launcher would refuse a disk others can read, so it is no VM.
        #expect(Darwin.chmod(disk.path, 0o644) == 0)
        #expect(!QEMUGPUStorageSpaceEstimate.hasRecordedPersistentDisk(stateRoot: root.path))
    }

    @Test("bundled metrics come from the factory manifest")
    func factoryMetrics() {
        let identity = String(repeating: "a", count: 64)
        let manifest = """
            {"format":1,"kind":"upstream-shell-factory","boot":"uefi-limine",
             "disk":{"path":"omarchy.img","bytes":21474836480,"sha256":"\(identity)"},
             "compressed":{"path":"omarchy.img.zst","sha256":"\(identity)"}}
            """
        let metrics = QEMUGPUStorageSpaceEstimate.factoryMetrics(Data(manifest.utf8))
        #expect(metrics == BundledGuestMetrics(
            identity: identity, sourceDiskBytes: 10_737_418_240, workingDiskBytes: 21_474_836_480
        ))
        for broken in [
            manifest.replacingOccurrences(of: "upstream-shell-factory", with: "other"),
            manifest.replacingOccurrences(of: "\"format\":1", with: "\"format\":2"),
            manifest.replacingOccurrences(of: identity, with: "not-a-hash"),
            "[]",
        ] {
            #expect(QEMUGPUStorageSpaceEstimate.factoryMetrics(Data(broken.utf8)) == nil)
        }
    }

    private func allocatedSize(of disk: URL) -> Int64? {
        guard let values = try? disk.resourceValues(forKeys: [
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
        ]),
              let bytes = values.totalFileAllocatedSize ?? values.fileAllocatedSize
        else { return nil }
        return Int64(bytes)
    }
}

@Suite("Bundled QEMU GPU launcher path")
struct QEMUGPULauncherPathTests {
    @Test("resolves only the executable inside the app resources")
    func resolvesExpectedLayout() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(try QEMUGPULauncherPath.resolve(bundleURL: fixture.app) == fixture.launcher)
    }

    @Test("rejects a launcher symlink")
    func rejectsLauncherSymlink() throws {
        let fixture = try makeFixture(createLauncher: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let other = fixture.root.appendingPathComponent("other-launcher")
        try Data("#!/bin/bash\nexit 0\n".utf8).write(to: other)
        #expect(Darwin.chmod(other.path, 0o755) == 0)
        try FileManager.default.createSymbolicLink(at: fixture.launcher, withDestinationURL: other)

        #expect(throws: HelperError.self) {
            try QEMUGPULauncherPath.resolve(bundleURL: fixture.app)
        }
    }

    @Test("rejects an app with the wrong bundle name")
    func rejectsWrongBundleName() throws {
        let fixture = try makeFixture(appName: "Other.app")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(throws: HelperError.self) {
            try QEMUGPULauncherPath.resolve(bundleURL: fixture.app)
        }
    }

    private struct PathFixture {
        let root: URL
        let app: URL
        let launcher: URL
    }

    private func makeFixture(
        appName: String = QEMUGPULauncherPath.appName,
        createLauncher: Bool = true
    ) throws -> PathFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omarchy-qemu-path-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent(appName, isDirectory: true)
        let scripts = app
            .appendingPathComponent("Contents/Resources/scripts", isDirectory: true)
        let launcher = scripts.appendingPathComponent(QEMUGPULauncherPath.launcherName)
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        if createLauncher {
            try Data("#!/bin/bash\nexit 0\n".utf8).write(to: launcher)
            #expect(Darwin.chmod(launcher.path, 0o755) == 0)
        }
        return PathFixture(
            root: root,
            app: app.resolvingSymlinksInPath(),
            launcher: launcher.resolvingSymlinksInPath()
        )
    }
}

@Suite("Microphone launch policy")
struct MicrophoneLaunchDecisionTests {
    @Test("denial keeps playback launchable and gives recovery instructions")
    func deniedStillLaunches() {
        let decision = MicrophoneLaunchDecision.make(for: .denied)
        #expect(decision.allowsLaunch)
        #expect(decision.warning?.contains("Audio playback will continue") == true)
        #expect(decision.warning?.contains("System Settings > Privacy & Security > Microphone") == true)
    }

    @Test("restriction keeps playback launchable with an administrator action")
    func restrictedStillLaunches() {
        let decision = MicrophoneLaunchDecision.make(for: .restricted)
        #expect(decision.allowsLaunch)
        #expect(decision.warning?.contains("Mac administrator") == true)
    }

    @Test("authorization launches without a warning")
    func authorizedHasNoWarning() {
        let decision = MicrophoneLaunchDecision.make(for: .authorized)
        #expect(decision.allowsLaunch)
        #expect(decision.warning == nil)
    }

    @Test("an unrequested microphone remains optional")
    func notDeterminedStillLaunches() {
        let decision = MicrophoneLaunchDecision.make(for: .notDetermined)
        #expect(decision.allowsLaunch)
        #expect(decision.warning?.contains("was not requested") == true)
    }
}

@Suite("Accessibility launch policy")
struct AccessibilityLaunchDecisionTests {
    @Test("an unavailable grant never blocks Omarchy startup")
    func unavailableStillLaunches() {
        let decision = AccessibilityLaunchDecision.make(for: .unavailable)
        #expect(decision.allowsLaunch)
        #expect(decision.warning?.contains("start without Command-to-Super mapping") == true)
        #expect(decision.warning?.contains("later launch") == true)
    }

    @Test("authorization launches without a warning")
    func authorizedHasNoWarning() {
        let decision = AccessibilityLaunchDecision.make(for: .authorized)
        #expect(decision.allowsLaunch)
        #expect(decision.warning == nil)
    }
}
