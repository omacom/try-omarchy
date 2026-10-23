import AppKit
import Darwin
import Foundation
import TryOmarchyKitClient

/// The helper's headless run mode (`--run-vm`): an app that embeds the kit
/// starts the VM through it, with the launcher's stored settings. The
/// launcher window opens only from Omarchy's Setup menu.
/// The protocol is in TryOmarchyKitClient/VMRunProtocol.swift.
@MainActor
final class VMRunModeController: NSObject, NSApplicationDelegate {
    static let shutdownTimeout: TimeInterval = 60

    private let configuration: VMRunConfiguration
    private let session: VMRunSession
    private let baseEnvironment: [String: String]
    private let bundle: Bundle
    private var shutdownRequested = false
    private var finished = false
    private let storageLocationStore = StorageLocationPreferenceStore(
        storage: LauncherSettingsFile.storageLocation(legacy: LauncherSettingsFile.fullAppPreferences(),
                                                      legacyIsWritable: false)
    )
    private var stateRoot: URL?
    private var bridgedNetwork: BridgedNetworkAvailability?
    private var currentBridgedNetwork: BridgedNetworkAvailability?
    private var settingsBridge: NativeSettingsBridge?
    private var settingsWindow: VMRunSettingsWindow?

    init(configuration: VMRunConfiguration, launcherURL: URL,
         baseEnvironment: [String: String] = ProcessInfo.processInfo.environment, bundle: Bundle = .main) {
        self.configuration = configuration
        self.baseEnvironment = baseEnvironment
        self.bundle = bundle
        session = VMRunSession(
            launcherURL: launcherURL,
            supervisor: QEMUGPUProcessSupervisor(standardInput: .nullDevice, standardOutput: .standardError),
            factoryManifest: FactoryDownloadManifest.bundled(bundle: bundle),
            bundlesFactoryImage: QEMUGPUStorageSpaceEstimate.bundlesFactoryImage(bundle: bundle),
            bundledMetrics: QEMUGPUStorageSpaceEstimate.bundledMetrics(bundle: bundle),
            downloadNetworkPolicy: .unmetered
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        session.onEvent = { [weak self] event in self?.handle(event) }
        session.observeHost()
        guard !shutdownRequested else { return finish(status: 0) }
        if let failure = Self.preflight(environment: baseEnvironment) { return fail(failure) }
        presentAsProduct()
        let networkLayout = NetworkServiceLayout(bundle: bundle)
        var asksForBridged = false
        guard case .success = resolveSettings(bridgedNetwork: {
            asksForBridged = true
            return .available
        }), asksForBridged else { return launch(networkLayout: networkLayout, bridgedNetwork: nil) }
        let productName = configuration.productName
        // Asking the daemon can wait for the client's XPC timeout, so it runs
        // off the main thread and a shutdown stays immediate.
        DispatchQueue.global(qos: .userInitiated).async {
            let availability = networkLayout.bridgedNetwork(productName: productName)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !self.shutdownRequested, !self.finished else { return }
                    self.launch(networkLayout: networkLayout, bridgedNetwork: availability)
                }
            }
        }
    }

    private func resolveSettings(bridgedNetwork: () -> BridgedNetworkAvailability)
        -> Result<VMRunLaunchSettings, VMRunError> {
        VMRunLaunchSettings.make(
            baseEnvironment: launchEnvironment(),
            configuration: configuration,
            storageLocation: storageLocationStore.load(),
            storageLocationProblem: storageLocationStore.problem(),
            settings: { [unowned self] root in self.vmSettings(root: root) },
            bridgedNetwork: bridgedNetwork,
            metrics: QEMUGPUStorageSpaceEstimate.bundledMetrics(bundle: bundle)
        )
    }

    private func launch(networkLayout: NetworkServiceLayout, bridgedNetwork availability: BridgedNetworkAvailability?) {
        let settings: VMRunLaunchSettings
        switch resolveSettings(bridgedNetwork: { availability ?? .available }) {
        case .success(let resolved): settings = resolved
        case .failure(let error): return fail(error)
        }
        stateRoot = settings.stateRoot
        bridgedNetwork = settings.bridgedNetwork
        if let notice = settings.notice { emit(.notice(notice)) }
        let context = VMRunSession.LaunchContext(
            environment: settings.environment,
            stateRoot: settings.stateRoot.path,
            storageUnavailableReason: nil,
            mayCreateFactoryRoot: true
        )
        session.start(arguments: [], context: { context }, beforeLaunch: { context in
            if networkLayout.registration == .thisApp,
               context.environment[VMNetworkPolicy.modeKey] == VMNetworkMode.bridged.rawValue {
                try NetworkService.prepare()
                try NetworkService.verifyConnection()
            }
            try PortForwardAvailability.validate(settings.portForwardMappings)
        })
    }

    /// Quitting from the settings window, the Dock or a logout shuts Omarchy
    /// down, as quitting the app that started it does. The process exits
    /// once Omarchy has.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        settingsWindow?.close()
        requestShutdown()
        return .terminateLater
    }

    /// The command, the end of standard input, or a first signal.
    func requestShutdown() {
        guard !shutdownRequested, !finished else { return }
        shutdownRequested = true
        if session.isDownloading {
            emit(.stopping)
            session.cancelDownload()
        } else if session.isRunning {
            emit(.stopping)
            if session.reachedStart {
                do { try session.powerDown(forceAfter: Self.shutdownTimeout) } catch { session.quit() }
            } else {
                session.quit()
            }
        } else if NSApp.isRunning {
            finish(status: 0)
        }
    }

    /// A signal: shut down on the first, stop at once on the next.
    func handleTerminationSignal() {
        if shutdownRequested && session.isRunning {
            session.quit()
        } else {
            requestShutdown()
        }
    }

    private func launchEnvironment() -> [String: String] {
        var environment = QEMUGPURuntimeEnvironment.sanitizedForLaunch(baseEnvironment)
        environment = AudioLaunchConfiguration.make(
            baseEnvironment: environment,
            preferences: .systemDefaults,
            catalog: CoreAudioHostAudioDeviceProvider().catalog()
        ).environment
        environment = LanguageLaunchConfiguration.make(baseEnvironment: environment).environment
        environment[VMRunBridges.environmentKey] = VMRunBridges.names(configuration.bridges)
        environment[ProductName.environmentKey] = configuration.productName
        environment[ProductName.iconEnvironmentKey] = configuration.iconPath
        environment[NativeInstallExports.environmentKey] = "1"
        return environment
    }

    /// The full app's older settings apply wherever the VM's file has none,
    /// except to a scratch VM chosen by the environment.
    private func vmSettings(root: URL) -> LauncherSettingsFile {
        let inheritsStateRoot = baseEnvironment[StorageLocationPolicy.environmentKey]?.isEmpty == false
        return LauncherSettingsFile.vmSettings(legacy: LauncherSettingsFile.fullAppPreferences(),
                                               legacyIsWritable: false,
                                               adoptsLegacy: { !inheritsStateRoot }) { root }
    }

    /// The process shows only the settings window and alerts, under the
    /// product's name and icon, never the kit's.
    private func presentAsProduct() {
        ApplicationPresentation.installMainMenu(in: NSApp, applicationName: configuration.productName,
                                                includesAppCommands: false)
        if let iconPath = configuration.iconPath, let icon = NSImage(contentsOfFile: iconPath) {
            NSApp.applicationIconImage = icon
        }
        let about = NSApp.mainMenu?.items.first?.submenu?.items
            .first { $0.action == #selector(NSApplication.orderFrontStandardAboutPanel(_:)) }
        about?.action = #selector(showAbout(_:))
        about?.target = self
    }

    @objc private func showAbout(_ sender: Any?) {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [.applicationName: configuration.productName]
        options[.applicationIcon] = NSApp.applicationIconImage
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    private func startSettingsBridge(qmpSocketPath: String) {
        guard let stateRoot else { return }
        let socket = URL(fileURLWithPath: qmpSocketPath).deletingLastPathComponent()
            .appendingPathComponent("settings.sock").path
        do {
            settingsBridge = try NativeSettingsBridge(socketPath: socket) { [weak self] in
                guard let self, !self.shutdownRequested, !self.finished else { return false }
                if self.settingsWindow == nil {
                    self.settingsWindow = VMRunSettingsWindow(
                        configuration: self.configuration,
                        stateRoot: stateRoot,
                        storageLocationStore: self.storageLocationStore,
                        settings: self.vmSettings(root: stateRoot),
                        bundle: self.bundle,
                        networkService: NetworkServiceControls.forRunMode(
                            layout: NetworkServiceLayout(bundle: self.bundle),
                            productName: self.configuration.productName,
                            started: { [weak self] in self?.bridgedNetwork },
                            current: { [weak self] in self?.currentBridgedNetwork })
                    )
                }
                self.recheckBridgedNetwork()
                return self.settingsWindow?.show() ?? false
            }
        } catch {
            fputs("[settings] \(error.localizedDescription)\n", stderr)
        }
    }

    /// The embedding app may set up its daemon while Omarchy runs, so the
    /// settings window asks again each time it opens, off the main thread.
    private func recheckBridgedNetwork() {
        let layout = NetworkServiceLayout(bundle: bundle)
        guard layout.registration == .embeddingApp else { return }
        let productName = configuration.productName
        DispatchQueue.global(qos: .userInitiated).async {
            let availability = layout.bridgedNetwork(productName: productName)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.currentBridgedNetwork = availability }
            }
        }
    }

    private func handle(_ event: VMRunSession.Event) {
        switch event {
        case .downloadProgress(let progress):
            emit(.progress(VMRunFailure.phase(progress.phase), percent: progress.percent))
        case .downloadFinished:
            break
        case .downloadCancelled:
            finish(status: 0)
        case .launchProgress(let progress):
            if let phase = VMRunPhase(rawValue: progress.phase.rawValue) {
                emit(.progress(phase, percent: progress.percent))
            }
        case .ready(let qmpSocketPath):
            startSettingsBridge(qmpSocketPath: qmpSocketPath)
            emit(.ready)
        case .launchFailed(let error):
            fail(VMRunFailure.error(for: error, productName: configuration.productName))
        case .hostWakeFailed(let error):
            emit(.error(VMRunError(code: .hostWakeFailed,
                message: "Omarchy could not continue after this Mac woke, so it is stopping. (\(error.localizedDescription))")))
            session.quit()
        case .volumeUnmounted:
            emit(.error(VMRunError(code: .storageDisconnected,
                message: "The drive holding Omarchy was removed while it was running, so Omarchy is stopping.")))
        case .exited(let exit):
            if let failure = exit.hostSleepControlFailure {
                emit(.error(VMRunError(code: .hostSleepUnavailable, message: failure)))
            } else if exit.status != 0, !exit.wasStopping {
                emit(.error(VMRunFailure.error(standardError: exit.standardError, status: exit.status,
                                               reachedStart: exit.reachedStart)))
            }
            finish(status: exit.status)
        }
    }

    private func fail(_ error: VMRunError) {
        emit(.error(error))
        finish(status: 1)
    }

    private func finish(status: Int32) {
        guard !finished else { return }
        finished = true
        emit(.exited(status: min(255, max(0, status))))
        Darwin.exit(status == 0 ? 0 : 1)
    }

    private func emit(_ event: VMRunEvent) {
        guard let line = try? event.encodedLine() else { return }
        VMRunOutput.write(line)
    }

    /// The run-mode integration test (macos/Tests/run-mode.test.sh) starts a
    /// launcher that runs no VM, on CI runners that have no hypervisor.
    /// VMRunClient never passes this on.
    static let skipPreflightKey = "OMARCHY_VM_RUN_TEST_SKIP_PREFLIGHT"

    static func preflight(environment: [String: String]) -> VMRunError? {
        environment[skipPreflightKey] == "1" ? nil : VMRunClient.preflight()
    }
}

/// Which optional bridges the launcher starts (run-qemu-gpu.sh). The settings
/// bridge always runs, so Omarchy's Setup menu shows its settings row.
enum VMRunBridges {
    static let environmentKey = "OMARCHY_QEMU_GPU_BRIDGES"

    static func names(_ bridges: [VMRunBridge]) -> String {
        (bridges.map(\.rawValue) + ["settings"]).joined(separator: " ")
    }
}

enum VMRunOutput {
    static func fail(_ error: VMRunError, status: Int32) -> Never {
        for event in [VMRunEvent.error(error), .exited(status: status)] {
            if let line = try? event.encodedLine() { write(line) }
        }
        exit(status)
    }

    static func write(_ data: Data) {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(STDOUT_FILENO, buffer.baseAddress! + offset, buffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }
}

/// Reads commands from standard input on its own thread. The end of input
/// means the app that started the run mode has gone, so Omarchy shuts down.
enum VMRunInput {
    static func readConfiguration() throws -> VMRunConfiguration {
        guard let line = readLine(strippingNewline: false) else { throw VMRunProtocolError.invalidConfiguration }
        return try VMRunConfiguration.decode(line: Data(line.utf8))
    }

    static func follow(onShutdown: @escaping @Sendable () -> Void) {
        Thread.detachNewThread {
            while let line = readLine(strippingNewline: false) {
                switch Result(catching: { try VMRunCommand.decode(line: Data(line.utf8)) }) {
                case .success(.shutdown):
                    onShutdown()
                case .failure:
                    fputs("omarchy-vm-helper: ignoring an unknown run mode command\n", stderr)
                }
            }
            onShutdown()
        }
    }
}

enum VMRunFailure {
    static func phase(_ phase: FactoryDownloadProgress.Phase) -> VMRunPhase {
        switch phase {
        case .waiting: .waitingForDownload
        case .downloading: .downloading
        case .retrying: .reconnecting
        case .paused: .paused
        case .verifying: .verifyingDownload
        }
    }

    static func error(for error: Error, productName: String) -> VMRunError {
        switch error {
        case let error as VMRunError:
            return error
        case FactoryDownloadError.damaged:
            return VMRunError(code: .imageDigestMismatch, message: error.localizedDescription)
        case FactoryDownloadError.insufficientSpace, FactoryDownloadError.diskFull:
            return VMRunError(code: .notEnoughSpace, message: error.localizedDescription)
        case is FactoryDownloadError:
            return VMRunError(code: .downloadFailed, message: error.localizedDescription)
        default:
            return VMRunError(code: .launchFailed, message: "\(productName) could not start Omarchy. \(error.localizedDescription)")
        }
    }

    /// The launcher's own explanation, its last `run-qemu-gpu:` line, decides
    /// the code. Without one, QEMU itself stopped.
    static func error(standardError: String, status: Int32, reachedStart: Bool) -> VMRunError {
        let explanation = standardError.components(separatedBy: .newlines)
            .last { $0.hasPrefix("run-qemu-gpu: ") }
            .map { String($0.dropFirst("run-qemu-gpu: ".count)) }
        let message = VMStartupFailure.message(status: status, standardError: standardError, otherApp: "Try Omarchy")
        guard !reachedStart, let explanation else {
            if standardError.contains("HV_") || standardError.localizedCaseInsensitiveContains("hvf") {
                return VMRunError(code: .hypervisorUnavailable, message: message)
            }
            return VMRunError(code: .qemuExited, message: message)
        }
        let codes: [(String, VMRunErrorCode)] = [
            ("this VM is already open", .vmAlreadyOpen),
            ("requires an APFS volume", .volumeNotAPFS),
            ("requires macOS", .macOSTooOld),
            ("requires an Apple Silicon Mac", .hypervisorUnavailable),
            ("not enough free space", .notEnoughSpace),
            ("factory image is damaged", .imageDigestMismatch),
            ("storage layout", .storageLayoutUnknown),
            ("storage folder", .storageUnavailable),
            ("storage location", .storageUnavailable),
            ("QEMU exited", .qemuExited),
        ]
        let code = codes.first { explanation.contains($0.0) }?.1 ?? .launchFailed
        return VMRunError(code: code, message: message)
    }
}
