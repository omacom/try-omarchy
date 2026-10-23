import AppKit
import ApplicationServices
import Darwin
import Foundation

@MainActor
final class HostPowerNotificationObserver {
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    init(
        center: NotificationCenter = NSWorkspace.shared.notificationCenter,
        onWillSleep: @escaping @MainActor () -> Void,
        onDidWake: @escaping @MainActor () -> Void
    ) {
        self.center = center
        tokens = [
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    onWillSleep()
                }
            },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    onDidWake()
                }
            },
        ]
    }

    func stop() {
        for token in tokens {
            center.removeObserver(token)
        }
        tokens = []
    }
}

@MainActor
final class VMApplicationController: NSObject, NSApplicationDelegate {
    private let initialArguments: [String]
    private let baseEnvironment: [String: String]
    private let session: VMRunSession
    private let preferenceStore: AudioRoutingPreferenceStore
    private let vmSettings: LauncherSettingsFile
    private let sharedFolderStore: SharedFolderPreferenceStore
    private let usbDeviceStore: USBDevicePreferenceStore
    private let portForwardingStore: PortForwardingPreferenceStore
    private let networkStore: VMNetworkPreferenceStore
    private let fullscreenPreferenceStore: FullscreenPreferenceStore
    private let dictationPreferenceStore: DictationPreferenceStore
    private let startupPreferenceStore: StartupPreferenceStore
    private let resourcePreferenceStore: VMResourcePreferenceStore
    private let resourceLimits: VMResourceLimits
    private let storageLocationStore: StorageLocationPreferenceStore
    private let volumeProbe: VolumeProbing
    private let volumeRootDetector: VolumeRootDetecting
    private let deviceProvider: HostAudioDeviceProviding
    private let bundledMetrics: BundledGuestMetrics?
    private var startMenuWindow: StartMenuWindow?
    private var settingsBridge: NativeSettingsBridge?
    private let disposableWorkspace = DisposableVMWorkspace()
    private var isDisposable: Bool { initialArguments.first == QEMUGPUStorageOption.ephemeral.rawValue }
    private var settingsReturnApplication: NSRunningApplication?
    private let appReleaseChecker: AppReleaseChecker
    private var appReleaseWindow: AppReleaseWindow?
    private var appReleasePromptScheduled = false
    private let activationController = ApplicationActivationController()
    private var applicationTerminationPending = false
    private var lifecycle: VMRunLifecycle { session.lifecycle }

    /// True while a modal alert this controller opened itself (rather than
    /// AppKit) is on screen awaiting a click. `finish()`'s watchdog checks
    /// this so it never yanks a dialog out from under the user; it reschedules
    /// instead of firing while this is true.
    private var isPresentingBlockingAlert = false

    private(set) var exitStatus: Int32 = 0

    init(
        launcherURL: URL,
        initialArguments: [String],
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        supervisor: QEMUGPUProcessSupervisor = QEMUGPUProcessSupervisor(),
        preferenceStore: AudioRoutingPreferenceStore = AudioRoutingPreferenceStore(),
        legacyPreferences: UserDefaults = .standard,
        startupPreferenceStore: StartupPreferenceStore = StartupPreferenceStore(),
        resourceLimits: VMResourceLimits = .current,
        volumeProbe: VolumeProbing = URLVolumeProbe(),
        volumeRootDetector: VolumeRootDetecting = FileManagerVolumeRootDetector(),
        deviceProvider: HostAudioDeviceProviding = CoreAudioHostAudioDeviceProvider(),
        bundledMetrics: BundledGuestMetrics? = QEMUGPUStorageSpaceEstimate.bundledMetrics(),
        factoryManifest: FactoryDownloadManifest? = FactoryDownloadManifest.bundled(),
        bundlesFactoryImage: Bool = QEMUGPUStorageSpaceEstimate.bundlesFactoryImage(),
        appReleaseChecker: AppReleaseChecker? = nil
    ) {
        self.initialArguments = initialArguments
        self.baseEnvironment = baseEnvironment
        self.session = VMRunSession(
            launcherURL: launcherURL,
            supervisor: supervisor,
            factoryManifest: factoryManifest,
            bundlesFactoryImage: bundlesFactoryImage,
            bundledMetrics: bundledMetrics
        )
        self.preferenceStore = preferenceStore
        let storageLocationStore = StorageLocationPreferenceStore(
            storage: LauncherSettingsFile.storageLocation(legacy: legacyPreferences)
        )
        let inheritsStateRoot = baseEnvironment[StorageLocationPolicy.environmentKey]?.isEmpty == false
        let vmSettings = LauncherSettingsFile.vmSettings(legacy: legacyPreferences,
                                                         adoptsLegacy: { !inheritsStateRoot }) {
            guard inheritsStateRoot || storageLocationStore.problem() == nil else { return nil }
            return QEMUGPUStorageSpaceEstimate.storageRootURL(environment: baseEnvironment,
                                                              preference: storageLocationStore.load())
        }
        self.vmSettings = vmSettings
        self.sharedFolderStore = SharedFolderPreferenceStore(storage: vmSettings)
        self.usbDeviceStore = USBDevicePreferenceStore(storage: vmSettings)
        self.portForwardingStore = PortForwardingPreferenceStore(storage: vmSettings)
        self.networkStore = VMNetworkPreferenceStore(storage: vmSettings)
        self.fullscreenPreferenceStore = FullscreenPreferenceStore(storage: vmSettings)
        self.dictationPreferenceStore = DictationPreferenceStore(storage: vmSettings)
        self.startupPreferenceStore = startupPreferenceStore
        self.resourcePreferenceStore = VMResourcePreferenceStore(storage: vmSettings)
        self.resourceLimits = resourceLimits
        self.storageLocationStore = storageLocationStore
        self.volumeProbe = volumeProbe
        self.volumeRootDetector = volumeRootDetector
        self.deviceProvider = deviceProvider
        self.bundledMetrics = bundledMetrics
        self.appReleaseChecker = appReleaseChecker ?? AppReleaseChecker()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        appReleaseChecker.onChange = { [weak self] in
            self?.startMenuWindow?.refreshAppReleaseStatus()
            self?.appReleaseWindow?.refresh()
            self?.scheduleAppReleasePrompt()
        }
        session.onEvent = { [weak self] event in self?.handle(event) }
        session.observeHost()
        let startupRoot = startupPreferenceRoot()
        let startAutomatically = StartupPolicy.shouldStartAutomatically(
            isEnabled: startupPreferenceStore.load(storageRoot: startupRoot),
            hasExistingVM: startupRoot.map {
                QEMUGPUStorageSpaceEstimate.hasRecordedPersistentDisk(stateRoot: $0.path)
            } ?? false,
            optionKeyHeld: NSEvent.modifierFlags.contains(.option),
            initialArguments: initialArguments
        )
        prepareStartMenu(startAutomatically: startAutomatically)
        appReleaseChecker.checkAutomaticallyIfDue()
        scheduleAppReleasePrompt()
    }

    private func scheduleAppReleasePrompt() {
        guard !appReleasePromptScheduled else { return }
        appReleasePromptScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appReleasePromptScheduled = false
            self.presentAppReleasePromptIfReady()
        }
    }

    private func presentAppReleasePromptIfReady() {
        let ready = NSApp.isActive && !isPresentingBlockingAlert
            && NSApp.modalWindow == nil && !lifecycle.isStopping && !lifecycle.isTerminating
            && appReleaseWindow?.isVisible != true
            && startMenuWindow?.canPresentAppReleasePrompt == true
        guard let release = appReleaseChecker.automaticPromptRelease(presentationReady: ready),
              let window = startMenuWindow?.window else { return }
        // Remember presentation before attaching the sheet to avoid duplicate prompts.
        appReleaseChecker.acknowledgeRelease(release)
        AppReleasePrompt.alert(for: release).beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(release.url)
            }
        }
    }

    @objc func checkForAppUpdates(_ sender: Any?) {
        activationController.reconcile()
        if appReleaseWindow == nil {
            appReleaseWindow = AppReleaseWindow(checker: appReleaseChecker)
        }
        appReleaseWindow?.show()
    }

    @objc func showSettings(_ sender: Any?) {
        if session.isRunning {
            _ = showRunningSettings()
        } else if !lifecycle.isStopping && !isPresentingBlockingAlert {
            startMenuWindow?.bringToFront()
        }
    }

    @objc func openHelpLink(_ sender: NSMenuItem) {
        guard let link = ApplicationHelpLink(rawValue: sender.tag) else { return }
        NSWorkspace.shared.open(link.url)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        activationController.reconcile()
        startMenuWindow?.applicationDidBecomeActive()
        scheduleAppReleasePrompt()
    }

    private func prepareStartMenu(startAutomatically: Bool, honorInitialReset: Bool = true) {
        activationController.setDesiredPolicy(ApplicationPresentation.prelaunchActivationPolicy)
        let resetOptions = [
            QEMUGPUStorageOption.resetStorage.rawValue,
            QEMUGPUStorageOption.resetStorageOnly.rawValue,
        ]
        let initialResetRequested = initialArguments.first.map(resetOptions.contains) ?? false
        let canResetStorage = initialArguments.first != QEMUGPUStorageOption.ephemeral.rawValue
        let startMenu = StartMenuWindow(
            accessibilityStatus: { AXIsProcessTrusted() },
            microphoneStatus: { MicrophonePreflight.authorizationState() },
            cameraStatus: { CameraPreflight.authorizationState() },
            requestAccessibility: { [weak self] in
                self?.requestOptionalAccessibilityPermission()
            },
            requestMicrophone: { completion in
                MicrophonePreflight.requestAccess(completion: completion)
            },
            requestCamera: { completion in
                CameraPreflight.requestAccess(completion: completion)
            },
            canResetStorage: canResetStorage,
            storageLocation: { [weak self] in
                guard canResetStorage, let self else { return nil }
                guard let root = QEMUGPUStorageSpaceEstimate.storageRootURL(
                    environment: self.baseEnvironment,
                    preference: self.storageLocationStore.load()
                ) else { return nil }
                return StorageLocationPolicy.displayPath(root.path, homeDirectory: Self.homeDirectory)
            },
            storageLocationURL: { [weak self] in
                guard canResetStorage, let self else { return nil }
                return QEMUGPUStorageSpaceEstimate.storageRootURL(
                    environment: self.baseEnvironment,
                    preference: self.storageLocationStore.load()
                )
            },
            storageLocationStatus: { [weak self] in
                self?.storageLocationMenuState() ?? .defaultLocation
            },
            validateStorageLocation: { [weak self] path in
                self?.validateStorageLocation(path)
            },
            chooseStorageLocation: { [weak self] path in
                self?.chooseStorageLocation(path)
            },
            useDefaultStorageLocation: { [weak self] in
                self?.useDefaultStorageLocation()
            },
            resetSettings: { [weak self] in
                self?.resetSettings()
            },
            deleteStorageLocation: { [weak self] source, identity, completion in
                self?.deleteStorageLocation(source, identity: identity, completion: completion)
            },
            discardStorageLocation: { [weak self] source, identity, completion in
                self?.discardPreviousStorageLocation(source, identity: identity, completion: completion)
            },
            moveStorageLocation: { [weak self] source, path, progress, completion in
                self?.moveStorageLocation(from: source, to: path, progress: progress, completion: completion)
            },
            sharedFolderStatus: { [weak self] in
                self?.sharedFolderMenuState() ?? SharedFolderMenuState.disabled
            },
            chooseSharedFolder: { [weak self] path in
                self?.chooseSharedFolder(path)
            },
            setSharedFolderEnabled: { [weak self] enabled in
                self?.setSharedFolderEnabled(enabled)
            },
            usbDeviceStatus: { [weak self] in
                self?.usbDeviceMenuState() ?? .disabled
            },
            connectedUSBDevices: { HostUSBDevices.connected() },
            saveUSBDevice: { [weak self] preference in
                self?.usbDeviceStore.save(preference)
            },
            portForwardingStatus: { [weak self] in
                self?.portForwardingStore.load() ?? []
            },
            savePortForwarding: { [weak self] mappings in
                self?.savePortForwarding(mappings)
            },
            resources: { [weak self, resourceLimits] in
                guard let self else { return resourceLimits.defaults }
                return self.resolvedResources()
            },
            resourceLimits: resourceLimits,
            minimumDiskGiB: { [weak self] in self?.minimumDiskGiB() ?? 1 },
            saveResources: { [weak self] resources in
                self?.resourcePreferenceStore.save(resources)
            },
            networkPreferences: { [weak self] in self?.resolvedNetworkPreferences() ?? VMNetworkPreferences() },
            saveNetworkPreferences: { [weak self] preferences in
                do { try self?.networkStore.save(preferences); return nil }
                catch { return error.localizedDescription }
            },
            networkIdentity: VMNetworkIdentityAccess.forLaunch(arguments: initialArguments,
                operation: { [weak self] arguments in
                    guard let self else { throw HelperError.io("The VM controller is unavailable.") }
                    return try self.networkIdentityOperation(arguments)
                }),
            immersiveMode: { [weak self] in
                self?.fullscreenPreferenceStore.load().isImmersive ?? true
            },
            setImmersiveMode: { [weak self] isImmersive in
                guard let store = self?.fullscreenPreferenceStore else { return }
                var preferences = store.load()
                preferences.isImmersive = isImmersive
                store.save(preferences)
            },
            notchAvailable: { HostDisplayCutouts.macHasNotch() },
            usesNotch: { [weak self] in
                self?.fullscreenPreferenceStore.load().usesNotch ?? true
            },
            setUsesNotch: { [weak self] usesNotch in
                guard let store = self?.fullscreenPreferenceStore else { return }
                var preferences = store.load()
                preferences.usesNotch = usesNotch
                store.save(preferences)
            },
            dictationSupported: DictationSupport.isAvailable,
            dictationEnabled: { [weak self] in
                self?.dictationPreferenceStore.load().isEnabled ?? DictationPreferences.defaults.isEnabled
            },
            setDictationEnabled: { [weak self] isEnabled in
                self?.dictationPreferenceStore.save(DictationPreferences(isEnabled: isEnabled))
            },
            startAutomatically: { [weak self] in
                guard let self else { return false }
                return self.startupPreferenceStore.load(storageRoot: self.startupPreferenceRoot())
            },
            setStartAutomatically: { [weak self] enabled in
                guard let self else { return "The VM controller is unavailable." }
                do {
                    if self.isDisposable { _ = try self.disposableWorkspace.prepare() }
                    guard let root = self.startupPreferenceRoot() else {
                        return "The VM data folder is unavailable."
                    }
                    try self.startupPreferenceStore.save(enabled, storageRoot: root)
                    return nil
                } catch { return error.localizedDescription }
            },
            appVersionLabel: appReleaseChecker.installed.label,
            appReleaseActionTitle: { [weak self] in
                self?.appReleaseChecker.menuTitle ?? "Check for Updates…"
            },
            checkForAppUpdates: { [weak self] in self?.checkForAppUpdates(nil) },
            permissionPromptShown: { UserDefaults.standard.bool(forKey: Self.permissionPromptShownKey) },
            setPermissionPromptShown: { UserDefaults.standard.set(true, forKey: Self.permissionPromptShownKey) },
            firstBootCompleted: { UserDefaults.standard.bool(forKey: Self.firstBootCompletedKey) },
            setFirstBootCompleted: { UserDefaults.standard.set(true, forKey: Self.firstBootCompletedKey) },
            launch: { [weak self] in
                self?.startVirtualMachine()
            }
        )
        startMenuWindow = startMenu
        startMenu.onAppReleasePromptOpportunity = { [weak self] in self?.scheduleAppReleasePrompt() }
        // Automatic startup uses the same launch path as the button.
        if startAutomatically {
            startMenu.launchOmarchy()
        } else {
            startMenu.show()
            if honorInitialReset && initialResetRequested {
                startMenu.promptForDeletion()
            }
        }
    }

    private func startupPreferenceRoot() -> URL? {
        if isDisposable { return disposableWorkspace.directory }
        return QEMUGPUStorageSpaceEstimate.storageRootURL(
            environment: baseEnvironment, preference: storageLocationStore.load()
        )
    }

    private func startVirtualMachine() {
        do {
            if isDisposable { _ = try disposableWorkspace.prepare() }
            let accessibilityDecision = AccessibilityLaunchDecision.make(
                for: AXIsProcessTrusted() ? .authorized : .unavailable
            )
            if let warning = accessibilityDecision.warning {
                fputs("[input-bridge] \(warning)\n", stderr)
            }
            guard accessibilityDecision.allowsLaunch else {
                throw HelperError.io("accessibility policy unexpectedly prevented launch")
            }
            let microphoneDecision = MicrophonePreflight.decision()
            if let warning = microphoneDecision.warning {
                fputs("[audio] \(warning)\n", stderr)
            }
            guard microphoneDecision.allowsLaunch else {
                throw HelperError.io("microphone policy unexpectedly prevented audio playback")
            }
            // Switching to the default is an acceptable way to start a VM, so
            // both `.available` and `.switchedToDefault` proceed here.
            guard isDisposable || resolveStorageLocationAvailability() != .cancelled else {
                startMenuWindow?.launchDidAbort()
                return
            }
            let cameraDecision = CameraPreflight.decision()
            if let warning = cameraDecision.warning {
                fputs("[camera] \(warning)\n", stderr)
            }
            guard cameraDecision.allowsLaunch else {
                throw HelperError.io("camera policy unexpectedly prevented launch")
            }
            session.start(arguments: launchArguments(), context: { [weak self] in
                self?.runContext() ?? VMRunSession.LaunchContext(environment: [:], stateRoot: nil,
                    storageUnavailableReason: "The VM controller is unavailable.", mayCreateFactoryRoot: false)
            }, beforeLaunch: { [weak self] context in
                if context.environment[VMNetworkPolicy.modeKey] == VMNetworkMode.bridged.rawValue {
                    try NetworkService.prepare()
                    try NetworkService.verifyConnection()
                }
                try PortForwardAvailability.validate(self?.childLaunchContext().portForwardMappings ?? [])
            })
        } catch {
            failLaunch(error)
        }
    }

    private func handle(_ event: VMRunSession.Event) {
        switch event {
        case .downloadProgress(let progress):
            startMenuWindow?.launchDidDownload(progress)
        case .downloadFinished:
            startMenuWindow?.launchDidFinishDownload()
        case .downloadCancelled:
            startMenuWindow?.launchDidAbort()
        case .launchProgress(let progress):
            startMenuWindow?.launchDidProgress(to: progress)
        case .ready(let qmpSocketPath):
            virtualMachineDidStart(qmpSocketPath: qmpSocketPath)
        case .launchFailed(let error):
            failLaunch(error)
        case .hostWakeFailed(let error):
            presentHostWakeRecovery(error: error)
        case .volumeUnmounted:
            presentVolumeUnmountAlert()
        case .exited(let exit):
            childDidExit(exit)
        }
    }

    private func launchArguments() -> [String] {
        var arguments = initialArguments
        let resetOptions = [
            QEMUGPUStorageOption.resetStorage.rawValue,
            QEMUGPUStorageOption.resetStorageOnly.rawValue,
        ]
        if let first = arguments.first,
           resetOptions.contains(first) || first == QEMUGPUStorageOption.ephemeral.rawValue {
            arguments.removeFirst()
        }
        return arguments
    }

    /// Every launcher setting returns to its default. Which VM is selected,
    /// the VM itself, and permission choices stay.
    private func resetSettings() {
        preferenceStore.save(.systemDefaults)
        sharedFolderStore.save(.disabled)
        usbDeviceStore.save(.disabled)
        try? portForwardingStore.save([])
        try? networkStore.save(VMNetworkPreferences())
        fullscreenPreferenceStore.save(.defaults)
        dictationPreferenceStore.save(.defaults)
        resourcePreferenceStore.clear()
        if let root = startupPreferenceRoot() {
            try? startupPreferenceStore.save(false, storageRoot: root)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if workspaceTransferProcess != nil { return .terminateCancel }
        session.cancelDownload()
        guard session.isRunning else { return .terminateNow }
        guard !applicationTerminationPending else { return .terminateLater }

        applicationTerminationPending = true
        session.quit()
        return .terminateLater
    }

    func handleTerminationSignal(_ signal: Int32) {
        if workspaceTransferProcess?.isRunning == true { workspaceTransferProcess?.terminate() }
        guard !applicationTerminationPending else { return }
        let wasRunning = session.isRunning
        session.terminate(signal: signal)
        if !wasRunning {
            finish(status: 128 + signal)
        }
    }

    private struct ChildLaunchContext {
        var environment: [String: String]
        let stateRoot: String?
        let portForwardMappings: [PortForwardMapping]
        /// Set when a chosen data folder could not be validated. Starting the
        /// launcher anyway would silently retarget the default workspace.
        let storageUnavailableReason: String?
    }

    private func runContext() -> VMRunSession.LaunchContext {
        let context = childLaunchContext()
        return VMRunSession.LaunchContext(
            environment: context.environment,
            stateRoot: context.stateRoot,
            storageUnavailableReason: context.storageUnavailableReason,
            mayCreateFactoryRoot: storageLocationStore.load().isDefault || storageEnvironmentOverride != nil
        )
    }

    private func networkIdentityOperation(_ arguments: [String]) throws -> String {
        let context = childLaunchContext()
        if let error = context.storageUnavailableReason { throw HelperError.io(error) }
        guard let root = QEMUGPUStorageSpaceEstimate.storageRootURL(
            environment: context.environment, preference: storageLocationStore.load()),
              let resources = Bundle.main.resourceURL else {
            throw HelperError.io("The VM data folder is unavailable.")
        }
        return try VMNetworkIdentityAccess.operation(arguments, root: root, resources: resources)
    }

    private func resolvedNetworkPreferences() -> VMNetworkPreferences {
        var preferences = networkStore.load()
        if preferences.mode == .bridged,
           let selected = VMBridgeInterfaces.available().first(where: { $0.name == preferences.interface }) {
            preferences.wifiCompatibility = VMNetworkPolicy.requiresWiFiCompatibility(
                isWiFi: selected.isWiFi, supported: VMNetworkPolicy.supportsWiFiCompatibility)
        }
        return preferences
    }

    private func minimumDiskGiB() -> Int {
        let root = disposableWorkspace.directory ?? QEMUGPUStorageSpaceEstimate.storageRootURL(
            environment: baseEnvironment, preference: storageLocationStore.load()
        )
        let disk = root?.appendingPathComponent("shell/disk.img")
        let attributes = disk.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path) }
        let bytes = (attributes?[.type] as? FileAttributeType) == .typeRegular
            ? (attributes?[.size] as? NSNumber)?.int64Value : nil
        let capacity = bytes ?? bundledMetrics?.workingDiskBytes ?? (16 << 30)
        return max(1, Int(max(0, capacity - 1) / (1 << 30)) + 1)
    }

    private func resolvedResources() -> VMResources {
        var resources = resourceLimits.resolve(resourcePreferenceStore.load())
        if let disk = resources.diskGiB {
            resources.diskGiB = max(disk, minimumDiskGiB())
        }
        return resources
    }

    /// The environment every launcher invocation receives.
    ///
    /// Reset must compose this exactly as a normal launch does. When the two
    /// diverged, choosing a custom data folder would leave Reset erasing the
    /// default workspace while the VM the user meant to erase stayed untouched.
    ///
    /// Port-forward availability is deliberately *not* validated here: this
    /// context is shared with Reset, and a reset that only wipes the VM disk
    /// should never fail because an unrelated port mapping is unavailable.
    /// `launch()` validates the composed mappings itself, after calling this.
    private func childLaunchContext(forReset: Bool = false) -> ChildLaunchContext {
        let audio = AudioLaunchConfiguration.make(
            baseEnvironment: QEMUGPURuntimeEnvironment.sanitizedForLaunch(baseEnvironment),
            preferences: preferenceStore.load(),
            catalog: deviceProvider.catalog()
        )
        let sharing = SharedFolderLaunchConfiguration.make(
            baseEnvironment: audio.environment,
            preference: sharedFolderStore.load(),
            homeDirectory: Self.homeDirectory
        )
        let usb = USBPassthroughLaunchConfiguration.make(
            baseEnvironment: sharing.environment,
            preference: usbDeviceStore.load(),
            connected: HostUSBDevices.connected()
        )
        let forwarding = PortForwardLaunchConfiguration.make(
            baseEnvironment: usb.environment,
            mappings: networkStore.load().mode == .nat ? portForwardingStore.load() : []
        )
        let fullscreen = FullscreenLaunchConfiguration.make(
            baseEnvironment: forwarding.environment,
            preferences: fullscreenPreferenceStore.load()
        )
        let dictation = DictationLaunchConfiguration.make(
            baseEnvironment: fullscreen.environment,
            preferences: dictationPreferenceStore.load(),
            isSupported: DictationSupport.isAvailable
        )
        let resources = VMResourceLaunchConfiguration.make(
            baseEnvironment: dictation.environment,
            preferences: resolvedResources(),
            limits: resourceLimits
        )
        let language = LanguageLaunchConfiguration.make(baseEnvironment: resources.environment)
        var storageEnvironment = language.environment
        if let directory = disposableWorkspace.directory {
            storageEnvironment[StorageLocationPolicy.environmentKey] = directory.path
            // A disposable session clones the main storage folder's factory
            // copy instead of decompressing its own.
            if let root = QEMUGPUStorageSpaceEstimate.storageRootURL(
                environment: baseEnvironment, preference: storageLocationStore.load()) {
                storageEnvironment[QEMUGPURuntimeEnvironment.factoryCacheKey] =
                    root.appendingPathComponent("shell-factory", isDirectory: true).path
            }
        }
        let storage = StorageLocationLaunchConfiguration.make(
            baseEnvironment: storageEnvironment,
            preference: storageLocationStore.load(),
            metrics: forReset ? nil : bundledMetrics,
            probe: volumeProbe,
            volumeRootDetector: volumeRootDetector
        )
        let pointerProblem = storageEnvironment[StorageLocationPolicy.environmentKey]?.isEmpty == false
            ? nil : storageLocationProblem()
        return ChildLaunchContext(
            environment: VMNetworkPolicy.environment(base: storage.environment, preferences: resolvedNetworkPreferences()),
            stateRoot: pointerProblem == nil ? storage.resolvedStateRoot?.path : nil,
            portForwardMappings: forwarding.mappings,
            storageUnavailableReason: storage.unavailableReason ?? pointerProblem
        )
    }

    private func virtualMachineDidStart(qmpSocketPath: String) {
        vmSettings.adoptLegacySettings()
        if let root = startupPreferenceRoot() {
            do { try startupPreferenceStore.persistPendingChoice(storageRoot: root) }
            catch { fputs("[startup] Could not retain Skip launcher: \(error.localizedDescription)\n", stderr) }
        }
        startMenuWindow?.dismiss()
        activationController.setDesiredPolicy(ApplicationPresentation.runningActivationPolicy)
        startMenuWindow?.virtualMachineDidStart(
            requestSettingsAction: { [weak self] action in self?.shutDownForSettings(action) },
            closeSettings: { [weak self] in self?.closeRunningSettings() }
        )
        let settingsSocket = URL(fileURLWithPath: qmpSocketPath)
            .deletingLastPathComponent().appendingPathComponent("settings.sock").path
        do {
            settingsBridge = try NativeSettingsBridge(socketPath: settingsSocket) { [weak self] in
                self?.showRunningSettings() ?? false
            }
        } catch {
            // Settings access is optional; losing it must not stop a running VM.
            fputs("[settings] \(error.localizedDescription)\n", stderr)
        }
    }

    private func showRunningSettings() -> Bool {
        guard session.isRunning, session.reachedStart,
              (!lifecycle.isStopping || lifecycle.settingsAction != nil),
              !isPresentingBlockingAlert, let startMenuWindow else { return false }
        activationController.reconcile()
        if startMenuWindow.window.isVisible || startMenuWindow.window.isMiniaturized {
            startMenuWindow.bringToFront()
            return true
        }
        settingsReturnApplication = NSWorkspace.shared.frontmostApplication
        startMenuWindow.show()
        return true
    }

    private func closeRunningSettings() {
        startMenuWindow?.dismiss()
        settingsReturnApplication?.activate(options: [])
        settingsReturnApplication = nil
    }

    private func shutDownForSettings(_ action: VMRunLifecycle.SettingsAction) {
        guard session.isRunning, session.reachedStart, !lifecycle.isStopping else { return }
        guard !session.pausedForHostSleep else {
            startMenuWindow?.shutdownDidFail("Wait for Omarchy to resume after Mac sleep, then try again.")
            return
        }
        session.requestSettingsAction(action)
        startMenuWindow?.shutdownDidBegin()
        do {
            // ACPI asks Linux to shut down cleanly. Only the launcher's exit
            // callback may start the replacement QEMU process; no forced timer.
            try session.powerDown()
        } catch {
            session.cancelSettingsAction()
            startMenuWindow?.shutdownDidFail(error.localizedDescription)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !session.isRunning { disposableWorkspace.remove() }
    }

    private static let permissionPromptShownKey = "LauncherPermissionPromptShown"
    private static let firstBootCompletedKey = "LauncherFirstBootCompleted"

    private static var homeDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    }

    private func sharedFolderMenuState() -> SharedFolderMenuState {
        SharedFolderMenuState.make(
            preference: sharedFolderStore.load(),
            homeDirectory: Self.homeDirectory
        )
    }

    /// Returns an error message when the folder is rejected; otherwise saves
    /// it as the enabled share.
    private func chooseSharedFolder(_ path: String) -> String? {
        do {
            let canonical = try SharedFolderPolicy.validate(path, homeDirectory: Self.homeDirectory)
            sharedFolderStore.save(SharedFolderPreference(path: canonical, isEnabled: true))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func usbDeviceMenuState() -> USBDeviceMenuState {
        USBDeviceMenuState.make(
            preference: usbDeviceStore.load(),
            connected: HostUSBDevices.connected(),
            environment: baseEnvironment
        )
    }

    private func setSharedFolderEnabled(_ enabled: Bool) {
        var preference = sharedFolderStore.load()
        guard preference.path != nil else { return }
        preference.isEnabled = enabled
        sharedFolderStore.save(preference)
    }

    private func savePortForwarding(_ mappings: [PortForwardMapping]) -> String? {
        do {
            try portForwardingStore.save(mappings)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func storageLocationMenuState() -> StorageLocationMenuState {
        if let problem = storageLocationProblem() {
            return StorageLocationMenuState(containerPath: nil, stateRoot: nil, displayPath: nil, volumeName: nil,
                                            isDefault: false, isExternal: false, problem: problem, warning: nil,
                                            isEnvironmentOverride: false)
        }
        return StorageLocationMenuState.make(
            preference: storageLocationStore.load(),
            metrics: bundledMetrics,
            homeDirectory: Self.homeDirectory,
            environmentOverride: storageEnvironmentOverride,
            probe: volumeProbe,
            volumeRootDetector: volumeRootDetector
        )
    }

    /// Returns an error message when the folder is rejected, changing nothing.
    private func validateStorageLocation(_ path: String) -> String? {
        do {
            _ = try StorageLocationPolicy.validate(
                path,
                metrics: bundledMetrics,
                probe: volumeProbe,
                volumeRootDetector: volumeRootDetector
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Returns an error message when the folder is rejected; otherwise stores
    /// it. Selecting a location never copies or replaces a VM.
    private func chooseStorageLocation(_ path: String) -> String? {
        do {
            let resolution = try StorageLocationPolicy.validate(
                path,
                metrics: bundledMetrics,
                probe: volumeProbe,
                volumeRootDetector: volumeRootDetector
            )
            try storageLocationStore.save(
                StorageLocationPreference(containerPath: resolution.containerPath)
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var workspaceTransferProcess: Process?

    private func moveStorageLocation(from source: String, to path: String,
        progress: @escaping (VMTransferProgress) -> Void, completion: @escaping (String?) -> Void) {
        guard !session.isRunning, storageEnvironmentOverride == nil,
              let root = startupPreferenceRoot(), root.path == source,
              let executable = Bundle.main.executableURL else {
            completion("Shut down Omarchy before relocating its VM. Environment overrides must be removed first.")
            return
        }
        // A separate process owns POSIX locks, so unrelated UI file reads
        // cannot release them. Preferences change only after verified success.
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--copy-vm", root.path, path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() }
        catch { completion(error.localizedDescription); return }
        workspaceTransferProcess = process
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let errorMessage: String
            do {
                errorMessage = try VMTransferOutput.read(from: errors.fileHandleForReading) { update in
                    DispatchQueue.main.async { progress(update) }
                }
            } catch {
                errorMessage = error.localizedDescription
                if process.isRunning { process.terminate() }
            }
            process.waitUntilExit()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.workspaceTransferProcess = nil
                guard process.terminationStatus == 0 else {
                    completion(errorMessage.isEmpty
                        ? "VM relocation failed. The original VM and selected location were retained."
                        : errorMessage)
                    return
                }
                completion(self.chooseStorageLocation(path))
            }
        }
    }

    private func deleteStorageLocation(_ source: String, identity: String, completion: @escaping (String?) -> Void) {
        guard storageEnvironmentOverride == nil, startupPreferenceRoot()?.path == source else {
            completion("Shut down Omarchy before deleting its VM. The selected VM must match the confirmed folder.")
            return
        }
        runWorkspaceHelper(["--trash-vm", source, identity],
            failure: "Could not move this VM to Trash. The selected folder was retained.", completion: completion)
    }

    /// The copy a move left behind. It is never the selected VM, so trashing
    /// it cannot strand the next launch.
    private func discardPreviousStorageLocation(_ source: String, identity: String, completion: @escaping (String?) -> Void) {
        guard !session.isRunning, workspaceTransferProcess == nil, storageEnvironmentOverride == nil,
              let selected = startupPreferenceRoot(), selected.path != source else {
            completion("Shut down Omarchy before deleting the previous copy.")
            return
        }
        runWorkspaceHelper(["--trash-vm", source, identity],
            failure: "Could not move the previous copy to Trash.", completion: completion)
    }

    /// Runs a workspace change in a separate helper process, which owns the
    /// POSIX lock so unrelated UI file reads cannot release it.
    private func runWorkspaceHelper(_ arguments: [String], failure: String,
        completion: @escaping (String?) -> Void) {
        guard !session.isRunning, workspaceTransferProcess == nil,
              let executable = Bundle.main.executableURL else {
            completion("Shut down Omarchy before changing its VM.")
            return
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() }
        catch { completion(error.localizedDescription); return }
        workspaceTransferProcess = process
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let message: String
            do { message = try VMTransferOutput.read(from: errors.fileHandleForReading) { _ in } }
            catch { message = error.localizedDescription; if process.isRunning { process.terminate() } }
            process.waitUntilExit()
            DispatchQueue.main.async { [weak self] in
                self?.workspaceTransferProcess = nil
                completion(process.terminationStatus == 0 ? nil : (message.isEmpty ? failure : message))
            }
        }
    }

    private func useDefaultStorageLocation() {
        try? storageLocationStore.save(.default)
    }

    /// What the user decided once their chosen drive turned out to be missing.
    ///
    /// Launch and reset must react differently, which is why this reports the
    /// choice instead of a bare yes/no. Switching to the default is a fine way
    /// to *start* a VM, but it must never be a way to *erase* one: the user
    /// confirmed erasing the workspace on their own drive, and the default
    /// workspace is a different VM they were never asked about.
    private enum StorageAvailability {
        case available
        case switchedToDefault
        case cancelled
    }

    /// Refuses to act on the default workspace behind the user's back when
    /// their chosen drive is missing. Silently falling back would create — or
    /// destroy — a second VM they never asked about, which is exactly the
    /// multi-workspace confusion the storage library works to avoid.
    /// The state root forced by the environment, if any.
    ///
    /// `StorageLocationLaunchConfiguration` lets this beat the stored
    /// preference, so anything that reports or gates on "the location" has to
    /// read it too. Otherwise the reset sheet names the folder the user picked
    /// while the launcher erases the one the environment chose.
    private var storageEnvironmentOverride: String? {
        let configured = baseEnvironment[StorageLocationPolicy.environmentKey]
        return (configured?.isEmpty == false) ? configured : nil
    }

    private func storageLocationProblem() -> String? {
        storageEnvironmentOverride == nil ? storageLocationStore.problem() : nil
    }

    private func resolveStorageLocationAvailability(forReset: Bool = false) -> StorageAvailability {
        // An override wins over the preference on the way to the launcher, so
        // the preference's reachability says nothing about this run. The
        // launcher validates the override itself and fails loudly.
        if storageEnvironmentOverride != nil { return .available }
        if let problem = storageLocationProblem() {
            startMenuWindow?.show()
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Omarchy\u{2019}s data folder is unknown"
            alert.informativeText = "\(problem) Fix or remove that file, then try again. Starting from the default folder could open a different VM."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return .cancelled
        }
        let preference = storageLocationStore.load()
        guard let container = preference.containerPath else { return .available }
        do {
            _ = try StorageLocationPolicy.validate(
                container,
                metrics: forReset ? nil : bundledMetrics,
                probe: volumeProbe,
                volumeRootDetector: volumeRootDetector
            )
            return .available
        } catch {
            startMenuWindow?.show()
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Omarchy\u{2019}s data folder is unavailable"
            alert.informativeText = """
                \(error.localizedDescription)

                Reconnect the drive and try again, or switch back to the default \
                folder. Switching does not delete the VM stored on that drive.
                """
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Use Default Folder")
            guard alert.runModal() == .alertSecondButtonReturn else { return .cancelled }
            try? storageLocationStore.save(.default)
            return .switchedToDefault
        }
    }

    private func presentHostWakeRecovery(error: Error) {
        guard session.isRunning,
              !lifecycle.isTerminating,
              session.pausedForHostSleep
        else { return }

        activationController.reconcile()
        defer { activationController.reconcile() }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Omarchy is still paused"
        alert.informativeText = "Try Omarchy could not reconnect after this Mac woke, so the VM remains paused to protect its state. Try again, or quit the app. (\(error.localizedDescription))"
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Quit Try Omarchy")

        isPresentingBlockingAlert = true
        let response = alert.runModal()
        isPresentingBlockingAlert = false
        if response == .alertFirstButtonReturn {
            session.beginResumeAfterHostWake()
        } else {
            NSApp.terminate(nil)
        }
    }

    private func presentVolumeUnmountAlert() {
        activationController.reconcile()
        defer { activationController.reconcile() }

        // This alert is the first UI this accessory app shows all session, so
        // it must activate itself or it can be created without ever becoming
        // key/visible (see the note in finish()).
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "The Omarchy disk was disconnected"
        alert.informativeText = "The drive holding this VM was removed while it was running, so Omarchy is shutting down. Reconnect the drive before launching again. Removing the drive while the VM is running can damage it."
        alert.addButton(withTitle: "OK")

        // The child's own completion callback can arrive and call finish()
        // while this modal call is still blocking below it on the stack — a
        // dispatched main-queue block still gets pumped by a nested modal run
        // loop. Mark the alert as blocking so that reentrant finish() call
        // waits for this dialog instead of tearing it down mid-read.
        isPresentingBlockingAlert = true
        alert.runModal()
        isPresentingBlockingAlert = false
    }

    private func requestOptionalAccessibilityPermission() {
        guard !AXIsProcessTrusted() else { return }
        // A replacement app can leave a disabled TCC row tied to the old
        // code signature. Reset only our own decision so the prompt below
        // registers the executable that is installed now.
        _ = AccessibilityPermissionRepair.resetStaleEntry()
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        guard let settingsURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NSWorkspace.shared.open(settingsURL)
        }
    }

    private func childDidExit(_ exit: VMRunSession.Exit) {
        settingsBridge?.stop()
        settingsBridge = nil
        settingsReturnApplication = nil
        if exit.reachedStart {
            startMenuWindow?.dismiss()
            startMenuWindow = nil
        }
        let status = exit.status
        let recentStandardError = exit.standardError
        let settingsAction = exit.settingsAction
        let presentation = VMExitPresentationDecision.make(
            status: status,
            reachedVirtualMachineStart: exit.reachedStart,
            wasStopping: exit.wasStopping
        )
        let hostSleepControlFailure = exit.hostSleepControlFailure
        if applicationTerminationPending {
            NSApp.reply(toApplicationShouldTerminate: true)
        } else if let hostSleepControlFailure {
            startMenuWindow?.launchDidFail(errorMessage: hostSleepControlFailure)
        } else if let settingsAction {
            // This transition deliberately bypasses automatic startup and the
            // original command-line reset request. Reset still needs a new click.
            prepareStartMenu(startAutomatically: false, honorInitialReset: false)
            if status != 0 {
                startMenuWindow?.shutdownDidFail("Omarchy stopped unexpectedly while shutting down. Your saved settings are ready for the next launch.")
            } else if settingsAction == .restart {
                startMenuWindow?.launchOmarchy()
            }
        } else {
            if presentation.showsStartupFailure,
               let startMenuWindow,
               let networkFailure = NetworkStartupFailure.message(standardError: recentStandardError) {
                startMenuWindow.launchDidFail(errorMessage: networkFailure)
                return
            }
            if presentation.showsStartupFailure,
               let startMenuWindow,
               let portFailure = PortForwardStartupFailure.message(
                   standardError: recentStandardError,
                   mappings: portForwardingStore.load()
               ) {
                startMenuWindow.launchDidFail(errorMessage: portFailure)
                return
            }
            if presentation.showsStartupFailure {
                let message = VMStartupFailure.message(
                    status: status,
                    standardError: recentStandardError
                )
                if let startMenuWindow {
                    startMenuWindow.launchDidFail(errorMessage: message)
                    return
                }
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "Try Omarchy couldn’t start"
                alert.informativeText = message
                alert.addButton(withTitle: "Close")
                alert.runModal()
            }
            finish(status: status)
        }
    }

    private func failLaunch(_ error: Error) {
        fputs("omarchy-vm-helper: \(error.localizedDescription)\n", stderr)
        guard let startMenuWindow else {
            finish(status: 1)
            return
        }
        startMenuWindow.launchDidFail(errorMessage: error.localizedDescription)
    }

    private func finish(status: Int32) {
        // The completion callback that reaches `finish()` can arrive while a
        // dialog this controller opened is still on screen — a dispatched
        // main-queue block is still pumped by a nested `runModal()` loop.
        // `NSApp.stop()` is not scoped to only the outer run loop: called
        // while a modal session is active, it can end THAT session too,
        // closing the alert before the user has read it. So the whole
        // shutdown sequence below waits for the alert to be dismissed on its
        // own, rather than only guarding the final forced exit.
        guard !isPresentingBlockingAlert else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.finish(status: status)
            }
            return
        }

        if !session.isRunning { disposableWorkspace.remove() }
        exitStatus = status

        // `stop` + a posted wake-up event only reliably pumps the run loop
        // for an app the window server considers active. This accessory app
        // never shows its own window once the VM is running — QEMU owns the
        // visible window as a separate process — so a path that reaches here
        // without our window ever having been key (an eject while running,
        // not a signal-driven quit) can leave the posted event unserviced and
        // the process running with nothing on screen. Activating first covers
        // that gap; the delayed hard exit is a backstop in case it does not.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.stop(nil)
        if let wakeUp = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        ) {
            NSApp.postEvent(wakeUp, atStart: false)
        }

        // Backstop: forces the process to exit if the run loop has not
        // already returned on its own. If `run()` has already returned by
        // the time this fires, the process has exited and this never runs.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            fputs("omarchy-vm-helper: forcing exit; the run loop did not stop on its own\n", stderr)
            Darwin.exit(status)
        }
    }
}
