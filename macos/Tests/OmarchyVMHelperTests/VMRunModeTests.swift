import Foundation
import Testing
@testable import OmarchyVMHelper
import TryOmarchyKitClient

struct VMRunProtocolTests {
    @Test func everyEventRoundTrips() throws {
        let events: [VMRunEvent] = [
            .progress(.downloading, percent: 42),
            .progress(.checking, percent: nil),
            .notice(VMRunNotice(code: .bridgedNetworkUnavailable, message: "Omarchy starts with shared networking.")),
            .ready,
            .stopping,
            .error(VMRunError(code: .vmAlreadyOpen, message: "Omarchy is open in Try Omarchy.")),
            .exited(status: 0),
            .exited(status: 143),
        ]
        for event in events {
            let line = try event.encodedLine()
            #expect(line.last == 0x0A)
            #expect(!line.dropLast().contains(0x0A))
            #expect(try VMRunEvent.decode(line: line) == event)
        }
        for phase in VMRunPhase.allCases {
            #expect(try VMRunEvent.decode(line: VMRunEvent.progress(phase, percent: 1).encodedLine())
                == .progress(phase, percent: 1))
        }
        for code in VMRunErrorCode.allCases {
            let event = VMRunEvent.error(VMRunError(code: code, message: code.rawValue))
            #expect(try VMRunEvent.decode(line: event.encodedLine()) == event)
        }
        for code in VMRunNoticeCode.allCases {
            let event = VMRunEvent.notice(VMRunNotice(code: code, message: code.rawValue))
            #expect(try VMRunEvent.decode(line: event.encodedLine()) == event)
        }
    }

    @Test func eventsANewerKitAddsAreSkippable() {
        for line in [#"{"version":1,"event":"launched"}"#,
                     #"{"version":1,"event":"notice","code":"usb-device-missing","message":"x","device":"y"}"#] {
            #expect(throws: VMRunProtocolError.unknownEvent) { try VMRunEvent.decode(line: Data(line.utf8)) }
        }
    }

    @Test func eventsANewerKitExtendsStillRead() throws {
        #expect(try VMRunEvent.decode(line: Data(#"{"version":1,"event":"ready","since":3}"#.utf8)) == .ready)
        let notice = #"{"version":1,"event":"notice","code":"bridged-network-unavailable","message":"x","interface":"en0"}"#
        #expect(try VMRunEvent.decode(line: Data(notice.utf8))
            == .notice(VMRunNotice(code: .bridgedNetworkUnavailable, message: "x")))
        let error = try VMRunEvent.decode(line: Data(#"{"version":1,"event":"error","code":"gpu-lost","message":"x","detail":1}"#.utf8))
        #expect(error == .error(VMRunError(code: .launchFailed, message: "x", reportedCode: "gpu-lost")))
        guard case .error(let failure) = error else { return }
        #expect(failure.reportedCode == "gpu-lost")
        #expect(VMRunError(code: .qemuExited, message: "x").reportedCode == "qemu-exited")
    }

    @Test func eventsAreValidatedStrictly() {
        let invalid = [
            #"{"version":2,"event":"ready"}"#,
            #"{"event":"ready"}"#,
            #"{"version":1,"event":"launched"}"#,
            #"{"version":1,"event":"progress","phase":"downloading","percent":101}"#,
            #"{"version":1,"event":"progress","phase":"downloading","percent":4.5}"#,
            #"{"version":1,"event":"progress","phase":"downloading","percent":true}"#,
            #"{"version":1,"event":"progress","phase":"teleporting"}"#,
            #"{"version":1,"event":"error","code":"qemu-exited"}"#,
            #"{"version":1,"event":"error","code":"","message":"x"}"#,
            #"{"version":1,"event":"notice","code":"bridged-network-unavailable"}"#,
            #"{"version":1,"event":"notice","code":7,"message":"x"}"#,
            #"{"version":1,"event":"exited","status":256}"#,
            #"{"version":1,"event":"exited","status":"0"}"#,
            #"["version",1]"#,
            "not json",
            #"{"version":1,"event":"ready"}"# + "\n" + #"{"version":1,"event":"ready"}"#,
            #"{"version":1,"event":"error","code":"qemu-exited","message":""#
                + String(repeating: "x", count: VMRunProtocol.maximumLineBytes) + #""}"#,
        ]
        for line in invalid {
            #expect(throws: (any Error).self) { try VMRunEvent.decode(line: Data(line.utf8)) }
        }
    }

    @Test func configurationRoundTripsAndRejectsUnsafeValues() throws {
        let configuration = VMRunConfiguration(
            productName: "Omarchy Installer",
            storageRoot: "/Users/someone/VM",
            bridges: [.clipboard, .camera],
            memoryMiB: 8_192,
            cpus: 4
        )
        #expect(try VMRunConfiguration.decode(line: configuration.encodedLine()) == configuration)
        let defaults = VMRunConfiguration(productName: "Omarchy Installer")
        #expect(try VMRunConfiguration.decode(line: defaults.encodedLine()) == defaults)
        #expect(defaults.bridges == VMRunBridge.allCases)
        #expect(defaults.network == .shared)

        var invalid: [VMRunConfiguration] = []
        for change: (inout VMRunConfiguration) -> Void in [
            { $0.productName = "" },
            { $0.productName = " Padded" },
            { $0.productName = "Two\nlines" },
            { $0.productName = String(repeating: "🇧🇷", count: 64) },
            { $0.productName = String(repeating: "x", count: 65) },
            { $0.storageRoot = "relative/VM" },
            { $0.storageRoot = "/a\nb" },
            { $0.bridges = [.camera, .camera] },
            { $0.memoryMiB = 512 },
            { $0.cpus = 0 },
        ] {
            var copy = defaults
            change(&copy)
            invalid.append(copy)
        }
        for configuration in invalid {
            #expect(throws: VMRunProtocolError.invalidConfiguration) { try configuration.encodedLine() }
        }
        for line in [
            #"{"version":1,"productName":"x","bridges":["settings"],"network":"shared"}"#,
            #"{"version":1,"productName":"x","bridges":[],"network":"shared","sharedFolder":"/"}"#,
            #"{"version":1,"productName":"x","bridges":[],"network":"host"}"#,
            #"{"version":2,"productName":"x","bridges":[],"network":"shared"}"#,
        ] {
            #expect(throws: (any Error).self) { try VMRunConfiguration.decode(line: Data(line.utf8)) }
        }
    }

    @Test func productNamesFitAFileName() throws {
        for name in [String(repeating: "x", count: 64), String(repeating: "é", count: 64),
                     String(repeating: "🇧🇷", count: 31)] {
            #expect(ProductName.validated(name) == name)
            let configuration = VMRunConfiguration(productName: name)
            #expect(try VMRunConfiguration.decode(line: configuration.encodedLine()) == configuration)
        }
        for name in [String(repeating: "🇧🇷", count: 64), String(repeating: "🇧🇷", count: 32), String(repeating: "x", count: 65)] {
            #expect(ProductName.validated(name) == nil)
            #expect(throws: VMRunProtocolError.invalidConfiguration) {
                try VMRunConfiguration(productName: name).encodedLine()
            }
        }
    }

    @Test func iconPathMustNameAnIconFile() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("vm-run-icon-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let icon = folder.appendingPathComponent("Installer.icns")
        let png = folder.appendingPathComponent("Installer.PNG")
        let text = folder.appendingPathComponent("Installer.txt")
        for file in [icon, png, text] { try Data("icon".utf8).write(to: file) }
        let directory = folder.appendingPathComponent("Folder.icns", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

        for path in [icon.path, png.path] {
            let configuration = VMRunConfiguration(productName: "Omarchy Installer", iconPath: path)
            #expect(try VMRunConfiguration.decode(line: configuration.encodedLine()) == configuration)
        }
        for path in ["Installer.icns", folder.appendingPathComponent("missing.icns").path, text.path, directory.path,
                     icon.path + "\n"] {
            let configuration = VMRunConfiguration(productName: "Omarchy Installer", iconPath: path)
            #expect(throws: VMRunProtocolError.invalidConfiguration) { try configuration.encodedLine() }
        }
        #expect(throws: VMRunProtocolError.invalidConfiguration) {
            try VMRunConfiguration.decode(line: Data(
                #"{"version":1,"productName":"x","iconPath":7,"bridges":[],"network":"shared"}"#.utf8))
        }
    }

    @Test func commandsAreValidated() throws {
        #expect(try VMRunCommand.decode(line: VMRunCommand.shutdown.encodedLine()) == .shutdown)
        #expect(throws: VMRunProtocolError.invalidCommand) {
            try VMRunCommand.decode(line: Data(#"{"version":1,"command":"reboot"}"#.utf8))
        }
    }
}

struct VMRunFailureTests {
    private static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("run-qemu-gpu.sh")

    @Test func launcherFailuresMapToStableCodes() throws {
        let cases: [(String, VMRunErrorCode)] = [
            ("this VM is already open", .vmAlreadyOpen),
            ("the Omarchy VM requires an APFS volume; /Volumes/USB is on exfat", .volumeNotAPFS),
            ("requires macOS 15 or newer", .macOSTooOld),
            ("requires an Apple Silicon Mac", .hypervisorUnavailable),
            ("not enough free space for the Omarchy VM: 9000 MiB required, 10 MiB available", .notEnoughSpace),
            ("the Omarchy factory image is damaged: /x.img.zst", .imageDigestMismatch),
            ("this VM uses a storage layout this version does not know; update the app", .storageLayoutUnknown),
            ("the VM storage folder is not owned by this user: /x", .storageUnavailable),
            ("QEMU exited before it was ready", .qemuExited),
            ("could not decompress the factory disk", .launchFailed),
        ]
        let script = try String(contentsOf: Self.script, encoding: .utf8)
        for (line, code) in cases {
            let error = VMRunFailure.error(standardError: "[qemu-gpu] Launch phase: checking\nrun-qemu-gpu: \(line)\n",
                                           status: 1, reachedStart: false)
            #expect(error.code == code, "\(line)")
            let stable = line.components(separatedBy: [":", ";"]).first!
                .replacingOccurrences(of: "15 or newer", with: "")
            #expect(script.contains(stable), "run-qemu-gpu.sh no longer says: \(stable)")
        }
        #expect(VMRunFailure.error(standardError: "Error: HV_UNSUPPORTED\n", status: 1, reachedStart: false).code
            == .hypervisorUnavailable)
        #expect(VMRunFailure.error(standardError: "run-qemu-gpu: this VM is already open\n", status: 1, reachedStart: true).code
            == .qemuExited)
        #expect(VMRunFailure.error(standardError: "run-qemu-gpu: this VM is already open\n", status: 1, reachedStart: false)
            .message == "Omarchy is already open in another app, such as Try Omarchy. Shut it down there, then start it again here.")
    }

    @Test func downloadFailuresMapToStableCodes() {
        #expect(VMRunFailure.error(for: FactoryDownloadError.damaged, productName: "X").code == .imageDigestMismatch)
        #expect(VMRunFailure.error(for: FactoryDownloadError.insufficientSpace(needed: 2, available: 1), productName: "X").code
            == .notEnoughSpace)
        #expect(VMRunFailure.error(for: FactoryDownloadError.diskFull(downloaded: 1), productName: "X").code == .notEnoughSpace)
        #expect(VMRunFailure.error(for: FactoryDownloadError.connection("offline"), productName: "X").code == .downloadFailed)
        #expect(VMRunFailure.error(for: FactoryDownloadError.unavailable(statusCode: 404), productName: "X").code
            == .downloadFailed)
    }

    @Test func everyProgressPhaseHasAProtocolPhase() {
        for phase in VMLaunchPhase.allCases {
            #expect(VMRunPhase(rawValue: phase.rawValue) != nil, "\(phase)")
        }
        for phase in [FactoryDownloadProgress.Phase.waiting, .downloading, .retrying, .paused, .verifying] {
            _ = VMRunFailure.phase(phase)
        }
    }
}

/// The client against a helper that speaks the protocol, and against the real
/// helper's run mode.
struct VMRunClientTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [VMRunEvent] = []
        private let done = DispatchSemaphore(value: 0)
        var onEvent: (@Sendable (VMRunEvent) -> Void)?

        func record(_ event: VMRunEvent) {
            lock.withLock { events.append(event) }
            onEvent?(event)
            if case .exited = event { done.signal() }
        }

        func wait() -> [VMRunEvent] {
            _ = done.wait(timeout: .now() + 20)
            return lock.withLock { events }
        }
    }

    private func fakeKit(helper: String) throws -> (TryOmarchyKit, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vm-run-\(UUID().uuidString)")
        let kit = root.appendingPathComponent(TryOmarchyKit.bundleName, isDirectory: true)
        let macOS = kit.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let executable = macOS.appendingPathComponent(TryOmarchyKit.helperName)
        try Data(helper.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (TryOmarchyKit(bundleURL: kit), root)
    }

    @Test func followsEventsAndShutsDown() throws {
        let (kit, root) = try fakeKit(helper: """
            #!/bin/bash
            [[ $1 == --run-vm ]] || exit 64
            IFS= read -r config
            [[ $config == *'"productName":"Omarchy Installer"'* && $config != *settings* ]] || exit 65
            echo '{"version":1,"event":"progress","phase":"downloading","percent":10}'
            echo '{"version":1,"event":"ready"}'
            IFS= read -r command
            [[ $command == '{"command":"shutdown","version":1}' ]] || exit 66
            echo '{"version":1,"event":"stopping"}'
            echo '{"version":1,"event":"exited","status":0}'
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = VMRunClient(kit: kit)
        let recorder = Recorder()
        recorder.onEvent = { event in if event == .ready { client.shutDown() } }
        try client.start(VMRunConfiguration(productName: "Omarchy Installer"), environment: [:]) { recorder.record($0) }
        #expect(recorder.wait() == [.progress(.downloading, percent: 10), .ready, .stopping, .exited(status: 0)])
    }

    @Test func startsAgainFromTheExitedEvent() throws {
        let (kit, root) = try fakeKit(helper: """
            #!/bin/bash
            read -r config
            echo '{"version":1,"event":"ready"}'
            echo '{"version":1,"event":"exited","status":0}'
            sleep 0.3
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = VMRunClient(kit: kit)
        let first = Recorder()
        let second = Recorder()
        let restart = Recorder()
        first.onEvent = { event in
            guard case .exited = event else { return }
            if client.isRunning { restart.record(.error(VMRunError(code: .launchFailed, message: "still running"))) }
            do {
                try client.start(VMRunConfiguration(productName: "Omarchy Installer"), environment: [:]) {
                    second.record($0)
                }
            } catch {
                restart.record(.error(VMRunError(code: .launchFailed, message: "\(error)")))
            }
            restart.record(.exited(status: 0))
        }
        try client.start(VMRunConfiguration(productName: "Omarchy Installer"), environment: [:]) { first.record($0) }
        #expect(first.wait() == [.ready, .exited(status: 0)])
        #expect(restart.wait() == [.exited(status: 0)])
        #expect(second.wait() == [.ready, .exited(status: 0)])
    }

    @Test func skipsEventsItDoesNotKnow() throws {
        let (kit, root) = try fakeKit(helper: """
            #!/bin/bash
            read -r config
            echo '{"version":1,"event":"teleported"}'
            echo '{"version":1,"event":"notice","code":"bridged-network-unavailable","message":"Shared instead."}'
            echo '{"version":1,"event":"ready"}'
            echo '{"version":1,"event":"exited","status":0}'
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = VMRunClient(kit: kit)
        let recorder = Recorder()
        try client.start(VMRunConfiguration(productName: "Omarchy Installer"), environment: [:]) { recorder.record($0) }
        #expect(recorder.wait() == [
            .notice(VMRunNotice(code: .bridgedNetworkUnavailable, message: "Shared instead.")), .ready, .exited(status: 0),
        ])
    }

    @Test func reportsAnExitWithoutTheLastEvent() throws {
        let (kit, root) = try fakeKit(helper: "#!/bin/bash\nread -r config\nexit 3\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = VMRunClient(kit: kit)
        let recorder = Recorder()
        try client.start(VMRunConfiguration(productName: "Omarchy Installer"), environment: [:]) { recorder.record($0) }
        #expect(recorder.wait() == [.exited(status: 3)])
        #expect(!client.isRunning)
    }

    @Test func stopsAHelperThatBreaksTheProtocol() throws {
        let (kit, root) = try fakeKit(helper: """
            #!/bin/bash
            read -r config
            trap 'exit 143' TERM
            echo '{"version":2,"event":"ready"}'
            while :; do sleep 0.1; done
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = VMRunClient(kit: kit)
        let recorder = Recorder()
        try client.start(VMRunConfiguration(productName: "Omarchy Installer"), environment: [:]) { recorder.record($0) }
        let events = recorder.wait()
        #expect(events.count == 2)
        guard case .error(let error) = events.first else { Issue.record("no error: \(events)"); return }
        #expect(error.code == .launchFailed)
        #expect(events.last == .exited(status: 143))
    }

    @Test func terminateSendsTheSecondSignalThatStopsAtOnce() throws {
        let (kit, root) = try fakeKit(helper: """
            #!/bin/bash
            read -r config
            signals=0
            trap 'signals=$((signals + 1))' TERM
            echo '{"version":1,"event":"ready"}'
            while ((signals < 2)); do sleep 0.05; done
            echo '{"version":1,"event":"exited","status":0}'
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = VMRunClient(kit: kit)
        let recorder = Recorder()
        recorder.onEvent = { event in if event == .ready { client.terminate(killAfter: 10) } }
        let started = Date()
        try client.start(VMRunConfiguration(productName: "Omarchy Installer"), environment: [:]) { recorder.record($0) }
        #expect(recorder.wait() == [.ready, .exited(status: 0)])
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func terminateKillsAHelperThatKeepsRunningAndStopsItsLauncher() throws {
        let launcherStopped = FileManager.default.temporaryDirectory
            .appendingPathComponent("vm-run-launcher-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: launcherStopped) }
        let (kit, root) = try fakeKit(helper: """
            #!/bin/bash
            read -r config
            bash -c 'trap "touch \(launcherStopped.path); exit 143" TERM; while :; do sleep 0.05; done' >/dev/null &
            trap '' TERM
            echo '{"version":1,"event":"ready"}'
            while :; do sleep 0.05; done
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = VMRunClient(kit: kit)
        let recorder = Recorder()
        recorder.onEvent = { event in if event == .ready { client.terminate(killAfter: 0.5) } }
        let started = Date()
        try client.start(VMRunConfiguration(productName: "Omarchy Installer"), environment: [:]) { recorder.record($0) }
        #expect(recorder.wait() == [.ready, .exited(status: 128 + SIGKILL)])
        #expect(Date().timeIntervalSince(started) < 5)
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: launcherStopped.path), Date() < deadline { usleep(50_000) }
        #expect(FileManager.default.fileExists(atPath: launcherStopped.path))
    }

    @Test func refusesAMissingKit() {
        let client = VMRunClient(kit: TryOmarchyKit(bundleURL: URL(fileURLWithPath: "/nonexistent/TryOmarchyKit.bundle")))
        #expect(throws: VMRunError.self) {
            try client.start(VMRunConfiguration(productName: "Omarchy Installer")) { _ in }
        }
    }

    @Test func cleansTheLaunchersTestSettings() {
        let environment = VMRunClient.cleanEnvironment([
            "HOME": "/Users/x", "OMARCHY_QEMU_GPU_STATE_ROOT": "/tmp/x", "TRYOMARCHY_NOTCH": "0",
            "SDL_AUDIO_DEVICE_NAME": "x", "PATH": "/usr/bin",
        ])
        #expect(environment == ["HOME": "/Users/x", "PATH": "/usr/bin"])
    }

    private static let helper = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/debug/omarchy-vm-helper")

    /// `swift test` builds the helper, so a missing one fails rather than skips.
    @Test func theHelpersRunModeSpeaksTheProtocol() throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.helper.path))
        let (kit, root) = try fakeKit(helper: "")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try kit.helperURL()
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.copyItem(at: Self.helper, to: executable)

        // A kit without its launch scripts fails cleanly, in the protocol.
        let client = VMRunClient(kit: kit)
        let recorder = Recorder()
        try client.start(VMRunConfiguration(productName: "Omarchy Installer"), environment: [:]) { recorder.record($0) }
        let events = recorder.wait()
        guard case .error(let error) = events.first else { Issue.record("no error: \(events)"); return }
        #expect(error.code == .launchFailed)
        #expect(events.last == .exited(status: 1))

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["--run-vm"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(#"{"version":1,"productName":"x","bridges":["settings"],"network":"shared"}"#.utf8 + [0x0A]))
        process.waitUntilExit()
        let lines = output.fileHandleForReading.readDataToEndOfFile().split(separator: 0x0A)
        #expect(try lines.map { try VMRunEvent.decode(line: Data($0)) } == [
            .error(VMRunError(code: .invalidConfiguration, message: "The run mode configuration is invalid.")),
            .exited(status: 64),
        ])
        #expect(process.terminationStatus == 64)
    }
}

/// The run mode starts the VM with what the launcher stored for it; the
/// configuration fills in only what was never stored.
struct VMRunLaunchSettingsTests {
    private struct Volume: VolumeProbing {
        func capabilities(at url: URL) throws -> VolumeCapabilities {
            VolumeCapabilities(typeName: "apfs", volumeName: "Drive", supportsCloning: true, supportsSparseFiles: true,
                               isLocal: true, isInternal: true, availableBytes: 500_000_000_000)
        }
    }

    private struct NotVolumeRoot: VolumeRootDetecting {
        func isVolumeRoot(_ url: URL) -> Bool { false }
    }

    private let limits = VMResourceLimits(hostCPUCount: 10, hostMemoryBytes: 32 << 30)

    private func resolve(
        _ configuration: VMRunConfiguration,
        storageLocation: StorageLocationPreference = .default,
        environment: [String: String] = [:],
        bridgedNetwork: BridgedNetworkAvailability = .unavailable("Bridged networking is not available in Omarchy Installer."),
        bridgeInterfaces: [VMBridgeInterface] = [VMBridgeInterface(name: "en7", title: "USB LAN (en7)", isWiFi: false),
                                                 VMBridgeInterface(name: "en0", title: "Wi-Fi (en0)", isWiFi: true)]
    ) -> Result<VMRunLaunchSettings, VMRunError> {
        VMRunLaunchSettings.make(
            baseEnvironment: environment,
            configuration: configuration,
            storageLocation: storageLocation,
            settings: { root in LauncherSettingsFile.vmSettings(legacy: nil) { root } },
            bridgedNetwork: { bridgedNetwork },
            bridgeInterfaces: { bridgeInterfaces },
            limits: limits,
            connectedUSBDevices: { [] },
            homeDirectory: "/Users/nobody",
            metrics: nil,
            probe: Volume(),
            volumeRootDetector: NotVolumeRoot()
        )
    }

    @Test func storedSettingsWinOverTheConfiguration() throws {
        let fixture = try LauncherSettingsFixture()
        try fixture.markWorkspace()
        let settings = fixture.vmSettings(legacy: false)
        VMResourcePreferenceStore(storage: settings).save(VMResources(cpuCount: 6, memoryGiB: 8, diskGiB: 96))
        try PortForwardingPreferenceStore(storage: settings).save([PortForwardPreset.ssh])
        FullscreenPreferenceStore(storage: settings).save(FullscreenPreferences(isImmersive: false, usesNotch: false, usesAllDisplays: false))
        try VMNetworkPreferenceStore(storage: settings).save(VMNetworkPreferences())

        let configuration = VMRunConfiguration(productName: "Omarchy Installer", storageRoot: fixture.root.path,
                                               memoryMiB: 4_096, cpus: 4, network: .bridged)
        let resolved = try resolve(configuration).get()
        #expect(resolved.stateRoot.path == fixture.root.path)
        #expect(resolved.portForwardMappings == [PortForwardPreset.ssh])
        let environment = resolved.environment
        #expect(environment[StorageLocationPolicy.environmentKey] == fixture.root.path)
        #expect(environment[VMResourceLaunchConfiguration.cpuEnvironmentKey] == "6")
        #expect(environment[VMResourceLaunchConfiguration.memoryEnvironmentKey] == "8192")
        #expect(environment[VMResourceLaunchConfiguration.diskEnvironmentKey] == "96")
        #expect(environment[PortForwardPolicy.environmentKey] != nil)
        #expect(environment[FullscreenLaunchConfiguration.immersiveEnvironmentKey] == "0")
        #expect(environment[FullscreenLaunchConfiguration.displaysEnvironmentKey] == "0")
        #expect(environment[VMNetworkPolicy.modeKey] == VMNetworkMode.nat.rawValue)
    }

    @Test func theConfigurationFillsInWhatWasNeverStored() throws {
        let fixture = try LauncherSettingsFixture()
        try fixture.markWorkspace()
        let configuration = VMRunConfiguration(productName: "Omarchy Installer", storageRoot: fixture.root.path,
                                               memoryMiB: 4_096, cpus: 4)
        let environment = try resolve(configuration).get().environment
        #expect(environment[VMResourceLaunchConfiguration.memoryEnvironmentKey] == "4096")
        #expect(environment[VMResourceLaunchConfiguration.cpuEnvironmentKey] == "4")
        #expect(environment[VMResourceLaunchConfiguration.diskEnvironmentKey] == nil)
        #expect(environment[VMNetworkPolicy.modeKey] == VMNetworkMode.nat.rawValue)

        let automatic = try resolve(VMRunConfiguration(productName: "Omarchy Installer",
                                                       storageRoot: fixture.root.path)).get().environment
        #expect(automatic[VMResourceLaunchConfiguration.memoryEnvironmentKey] == nil)
        #expect(automatic[VMResourceLaunchConfiguration.cpuEnvironmentKey] == nil)
    }

    @Test func bridgedNeedsTheNetworkingDaemon() throws {
        let fixture = try LauncherSettingsFixture()
        try fixture.markWorkspace()
        let bridged = VMRunConfiguration(productName: "Omarchy Installer", storageRoot: fixture.root.path, network: .bridged)
        let unavailable = BridgedNetworkAvailability.unavailable("Omarchy Installer has not set up its networking helper.")
        guard case .failure(let error) = resolve(bridged, bridgedNetwork: unavailable) else {
            Issue.record("bridged started without the daemon"); return
        }
        #expect(error == VMRunError(code: .bridgedNetworkUnavailable,
                                    message: "Omarchy Installer has not set up its networking helper."))
        let started = try resolve(bridged, bridgedNetwork: .available).get()
        #expect(started.environment[VMNetworkPolicy.modeKey] == VMNetworkMode.bridged.rawValue)
        #expect(started.bridgedNetwork == .available && started.notice == nil)
    }

    @Test func bridgedFromTheConfigurationUsesTheInterfaceTheSettingsSelectFirst() throws {
        let fixture = try LauncherSettingsFixture()
        try fixture.markWorkspace()
        let bridged = VMRunConfiguration(productName: "Omarchy Installer", storageRoot: fixture.root.path, network: .bridged)
        let wifi = VMBridgeInterface(name: "en0", title: "Wi-Fi (en0)", isWiFi: true)
        let environment = try resolve(bridged, bridgedNetwork: .available, bridgeInterfaces: [wifi]).get().environment
        #expect(environment[VMNetworkPolicy.interfaceKey] == "en0")
        #expect(environment[VMNetworkPolicy.compatibilityKey]
            == (VMNetworkPolicy.supportsWiFiCompatibility ? "1" : "0"))
        let wired = try resolve(bridged, bridgedNetwork: .available).get().environment
        #expect(wired[VMNetworkPolicy.interfaceKey] == "en7")
        #expect(wired[VMNetworkPolicy.compatibilityKey] == "0")
        #expect(VMBridgeInterfaces.unchosenDefault(in: [wifi]) == wifi)

        guard case .failure(let error) = resolve(bridged, bridgedNetwork: .available, bridgeInterfaces: []) else {
            Issue.record("bridged started with no interface to bridge"); return
        }
        #expect(error.code == .bridgedNetworkUnavailable)
    }

    @Test func aStoredBridgedChoiceStartsSharedAndSaysSo() throws {
        let fixture = try LauncherSettingsFixture()
        try fixture.markWorkspace()
        try VMNetworkPreferenceStore(storage: fixture.vmSettings(legacy: false))
            .save(VMNetworkPreferences(mode: .bridged, interface: "en0"))
        let shared = VMRunConfiguration(productName: "Omarchy Installer", storageRoot: fixture.root.path)
        let unavailable = BridgedNetworkAvailability.unavailable("Omarchy Installer has not set up its networking helper.")
        let fallback = try resolve(shared, bridgedNetwork: unavailable).get()
        #expect(fallback.environment[VMNetworkPolicy.modeKey] == VMNetworkMode.nat.rawValue)
        #expect(fallback.bridgedNetwork == unavailable)
        #expect(fallback.notice == VMRunNotice(code: .bridgedNetworkUnavailable,
            message: "Omarchy Installer has not set up its networking helper. Omarchy starts with shared networking."))

        let bridged = try resolve(shared, bridgedNetwork: .available).get()
        #expect(bridged.environment[VMNetworkPolicy.modeKey] == VMNetworkMode.bridged.rawValue)
        #expect(bridged.notice == nil)
    }

    @Test func sharedNetworkingNeverAsksTheDaemon() throws {
        let fixture = try LauncherSettingsFixture()
        try fixture.markWorkspace()
        let configuration = VMRunConfiguration(productName: "Omarchy Installer", storageRoot: fixture.root.path)
        let resolved = VMRunLaunchSettings.make(
            baseEnvironment: [:], configuration: configuration, storageLocation: .default,
            settings: { root in LauncherSettingsFile.vmSettings(legacy: nil) { root } },
            bridgedNetwork: { Issue.record("checked bridged networking"); return .available },
            limits: limits, connectedUSBDevices: { [] },
            homeDirectory: "/Users/nobody", metrics: nil, probe: Volume(), volumeRootDetector: NotVolumeRoot())
        let settings = try resolved.get()
        #expect(settings.bridgedNetwork == nil && settings.notice == nil)
    }

    @Test func theConfiguredFolderWinsOverTheChosenOneAndTheEnvironmentOverrideWinsOverBoth() throws {
        let chosen = try LauncherSettingsFixture()
        let configured = try LauncherSettingsFixture()
        let override = try LauncherSettingsFixture()
        for fixture in [chosen, configured, override] { try fixture.markWorkspace() }
        let configuration = VMRunConfiguration(productName: "Omarchy Installer", storageRoot: configured.root.path)
        let unnamed = VMRunConfiguration(productName: "Omarchy Installer")
        let preference = StorageLocationPreference(containerPath: chosen.root.path)
        let chosenRoot = StorageLocationPolicy.stateRoot(forContainer: chosen.root.resolvingSymlinksInPath().path)

        #expect(try resolve(configuration).get().stateRoot.path == configured.root.path)
        #expect(try resolve(configuration, storageLocation: preference).get().stateRoot.path == configured.root.path)
        #expect(try resolve(unnamed, storageLocation: preference).get().stateRoot.path == chosenRoot)
        let overridden = try resolve(configuration, storageLocation: preference,
            environment: [StorageLocationPolicy.environmentKey: override.root.path]).get()
        #expect(overridden.stateRoot.path == override.root.path)

        let missing = StorageLocationPreference(containerPath: chosen.root.appendingPathComponent("gone").path)
        #expect(try resolve(configuration, storageLocation: missing).get().stateRoot.path == configured.root.path)
        guard case .failure(let error) = resolve(unnamed, storageLocation: missing) else {
            Issue.record("a missing chosen folder fell back to another VM"); return
        }
        #expect(error.code == .storageUnavailable)
    }

    @Test func theWindowShowsTheResourcesTheVMStartedWith() throws {
        let configured = VMRunConfiguration(productName: "Omarchy Installer", memoryMiB: 4_096, cpus: 4)
        let shown = VMRunLaunchSettings.shownResources(stored: nil, configuration: configured, limits: limits)
        #expect(shown.cpuCount == 4)
        #expect(shown.memoryGiB == 4)
        let stored = VMResources(cpuCount: 6, memoryGiB: 8, diskGiB: 96)
        #expect(VMRunLaunchSettings.shownResources(stored: stored, configuration: configured, limits: limits) == stored)
        #expect(VMRunLaunchSettings.shownResources(stored: nil, configuration: VMRunConfiguration(productName: "x"),
                                                   limits: limits) == limits.defaults)
    }

    @Test func anUnreadableFolderChoiceNeverFallsBackToAnotherVM() throws {
        let fixture = try LauncherSettingsFixture()
        try fixture.markWorkspace()
        let start = { (configuration: VMRunConfiguration) in
            VMRunLaunchSettings.make(
                baseEnvironment: [:], configuration: configuration, storageLocation: .default,
                storageLocationProblem: "storage-location.json is not a private file.",
                settings: { root in LauncherSettingsFile.vmSettings(legacy: nil) { root } },
                bridgedNetwork: { Issue.record("checked bridged networking"); return .available },
                limits: limits, connectedUSBDevices: { [] },
                homeDirectory: "/Users/nobody", metrics: nil, probe: Volume(), volumeRootDetector: NotVolumeRoot())
        }
        guard case .failure(let error) = start(VMRunConfiguration(productName: "Omarchy Installer")) else {
            Issue.record("started without knowing the VM folder"); return
        }
        #expect(error.code == .storageUnavailable)
        let named = VMRunConfiguration(productName: "Omarchy Installer", storageRoot: fixture.root.path)
        #expect(try start(named).get().stateRoot.path == fixture.root.path)
    }

    @Test func developmentOverridesStillWin() throws {
        let fixture = try LauncherSettingsFixture()
        try fixture.markWorkspace()
        try PortForwardingPreferenceStore(storage: fixture.vmSettings(legacy: false)).save([PortForwardPreset.ssh])
        let configuration = VMRunConfiguration(productName: "Try Omarchy", storageRoot: fixture.root.path)
        let resolved = try resolve(configuration, environment: [
            PortForwardPolicy.environmentKey: "tcp:2299:22",
            FullscreenLaunchConfiguration.immersiveEnvironmentKey: "0",
        ]).get()
        #expect(resolved.environment[PortForwardPolicy.environmentKey] == "tcp:2299:22")
        #expect(resolved.environment[FullscreenLaunchConfiguration.immersiveEnvironmentKey] == "0")
        #expect(resolved.portForwardMappings.isEmpty)
    }

    @Test func theSettingsBridgeAlwaysRuns() {
        #expect(VMRunBridges.names([]) == "settings")
        #expect(VMRunBridges.names([.clipboard, .timezone]) == "clipboard timezone settings")
    }
}

struct VMRunSessionDownloadTests {
    @MainActor @Test func aCancelledDownloadNeverStartsTheVM() {
        let image = URL(fileURLWithPath: "/tmp/factory.img.zst")
        guard case .launch(image) = VMRunSession.downloadOutcome(.success(image), cancelled: false) else {
            Issue.record("a finished download did not start the VM"); return
        }
        guard case .cancelled = VMRunSession.downloadOutcome(.success(image), cancelled: true) else {
            Issue.record("a download cancelled as it finished still started the VM"); return
        }
        guard case .cancelled = VMRunSession.downloadOutcome(.failure(FactoryDownloadError.cancelled), cancelled: true)
        else { Issue.record("a cancelled download was reported as a failure"); return }
        guard case .failed = VMRunSession.downloadOutcome(.failure(FactoryDownloadError.damaged), cancelled: false)
        else { Issue.record("a failed download was not reported"); return }
    }
}
