import AppKit
import ApplicationServices
import Foundation
import TryOmarchyKitClient

/// The run mode's launch settings: the VM folder the configuration names, or
/// else the one chosen in Try Omarchy, and what the launcher window stored for
/// that VM, with the configuration only where nothing is stored.
struct VMRunLaunchSettings {
    let environment: [String: String]
    let stateRoot: URL
    let portForwardMappings: [PortForwardMapping]
    let bridgedNetwork: BridgedNetworkAvailability?
    let notice: VMRunNotice?

    /// Development and test overrides, as with `OMARCHY_QEMU_GPU_STATE_ROOT`.
    /// An embedding app starts the run mode without them (VMRunClient).
    static let environmentOverrides = [
        PortForwardPolicy.environmentKey,
        SharedFolderPolicy.environmentKey,
        FullscreenLaunchConfiguration.immersiveEnvironmentKey,
        FullscreenLaunchConfiguration.notchEnvironmentKey,
        VMResourceLaunchConfiguration.memoryEnvironmentKey,
        VMResourceLaunchConfiguration.cpuEnvironmentKey,
        VMResourceLaunchConfiguration.diskEnvironmentKey,
    ]

    static func make(
        baseEnvironment: [String: String],
        configuration: VMRunConfiguration,
        storageLocation: StorageLocationPreference,
        storageLocationProblem: String? = nil,
        settings: (URL) -> any LauncherSettingsStorage,
        bridgedNetwork: () -> BridgedNetworkAvailability,
        bridgeInterfaces: () -> [VMBridgeInterface] = { VMBridgeInterfaces.available() },
        limits: VMResourceLimits = .current,
        connectedUSBDevices: () -> [USBDeviceIdentity] = { HostUSBDevices.connected() },
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path,
        metrics: BundledGuestMetrics?,
        probe: VolumeProbing = URLVolumeProbe(),
        volumeRootDetector: VolumeRootDetecting = FileManagerVolumeRootDetector()
    ) -> Result<Self, VMRunError> {
        var environment = baseEnvironment
        let inheritsStateRoot = environment[StorageLocationPolicy.environmentKey]?.isEmpty == false
        if !inheritsStateRoot, let storageRoot = configuration.storageRoot {
            environment[StorageLocationPolicy.environmentKey] = storageRoot
        } else if !inheritsStateRoot, let storageLocationProblem {
            return .failure(VMRunError(code: .storageUnavailable, message: storageLocationProblem))
        }
        let storage = StorageLocationLaunchConfiguration.make(
            baseEnvironment: environment,
            preference: storageLocation,
            metrics: metrics,
            probe: probe,
            volumeRootDetector: volumeRootDetector
        )
        guard storage.unavailableReason == nil, let stateRoot = storage.resolvedStateRoot else {
            return .failure(VMRunError(code: .storageUnavailable,
                message: storage.unavailableReason ?? "The VM's storage folder is not usable."))
        }
        let stored = settings(stateRoot)
        lazy var interfaces = bridgeInterfaces()

        var network: VMNetworkPreferences
        var availability: BridgedNetworkAvailability?
        var notice: VMRunNotice?
        if stored.settingData(forKey: VMNetworkPreferenceStore.key) != nil {
            network = VMNetworkPreferenceStore(storage: stored).load()
            if network.mode == .bridged {
                availability = bridgedNetwork()
                if case .unavailable(let reason) = availability {
                    fputs("[network] \(reason) Omarchy starts with shared networking.\n", stderr)
                    notice = VMRunNotice(code: .bridgedNetworkUnavailable,
                                         message: "\(reason) Omarchy starts with shared networking.")
                    network = VMNetworkPreferences()
                }
            }
        } else {
            network = VMNetworkPreferences()
            if configuration.network == .bridged {
                availability = bridgedNetwork()
                if case .unavailable(let reason) = availability {
                    return .failure(VMRunError(code: .bridgedNetworkUnavailable, message: reason))
                }
                guard let interface = VMBridgeInterfaces.unchosenDefault(in: interfaces) else {
                    return .failure(VMRunError(code: .bridgedNetworkUnavailable,
                                               message: "This Mac has no network connection Omarchy can bridge."))
                }
                network.mode = .bridged
                network.interface = interface.name
            }
        }
        if network.mode == .bridged,
           let selected = interfaces.first(where: { $0.name == network.interface }) {
            network.wifiCompatibility = VMNetworkPolicy.requiresWiFiCompatibility(
                isWiFi: selected.isWiFi, supported: VMNetworkPolicy.supportsWiFiCompatibility)
        }

        let sharing = SharedFolderLaunchConfiguration.make(
            baseEnvironment: storage.environment,
            preference: SharedFolderPreferenceStore(storage: stored).load(),
            homeDirectory: homeDirectory
        )
        let usb = USBPassthroughLaunchConfiguration.make(
            baseEnvironment: sharing.environment,
            preference: USBDevicePreferenceStore(storage: stored).load(),
            connected: connectedUSBDevices()
        )
        let forwarding = PortForwardLaunchConfiguration.make(
            baseEnvironment: usb.environment,
            mappings: network.mode == .nat ? PortForwardingPreferenceStore(storage: stored).load() : []
        )
        var resolved = FullscreenLaunchConfiguration.make(
            baseEnvironment: forwarding.environment,
            preferences: FullscreenPreferenceStore(storage: stored).load()
        ).environment
        if let resources = VMResourcePreferenceStore(storage: stored).load() {
            resolved = VMResourceLaunchConfiguration.make(
                baseEnvironment: resolved, preferences: resources, limits: limits
            ).environment
        } else {
            if let memory = configuration.memoryMiB {
                resolved[VMResourceLaunchConfiguration.memoryEnvironmentKey] = String(memory)
            }
            if let cpus = configuration.cpus {
                resolved[VMResourceLaunchConfiguration.cpuEnvironmentKey] = String(cpus)
            }
        }
        var mappings = forwarding.mappings
        for key in environmentOverrides {
            guard let value = baseEnvironment[key], !value.isEmpty else { continue }
            resolved[key] = value
            if key == PortForwardPolicy.environmentKey { mappings = [] }
        }
        return .success(Self(
            environment: VMNetworkPolicy.environment(base: resolved, preferences: network),
            stateRoot: stateRoot,
            portForwardMappings: mappings,
            bridgedNetwork: availability,
            notice: notice
        ))
    }
}

extension VMRunLaunchSettings {
    /// What the settings window shows, and so what a save keeps: the stored
    /// resources, or else the configuration's that the VM started with.
    static func shownResources(stored: VMResources?, configuration: VMRunConfiguration,
                               limits: VMResourceLimits) -> VMResources {
        if let stored { return limits.resolve(stored) }
        var resources = limits.defaults
        if let cpus = configuration.cpus { resources.cpuCount = cpus }
        if let memory = configuration.memoryMiB { resources.memoryGiB = memory / 1024 }
        return resources
    }
}

/// The launcher window, opened from Omarchy's Setup menu while another app
/// runs the VM, named after that app. Like the full app's settings while
/// Omarchy runs, it is an accessory window: no second name in the Dock.
@MainActor
final class VMRunSettingsWindow {
    private let configuration: VMRunConfiguration
    private let stateRoot: URL
    private let storageLocationStore: StorageLocationPreferenceStore
    private let settings: LauncherSettingsFile
    private let bundle: Bundle
    private let networkService: NetworkServiceControls
    private let activationController = ApplicationActivationController()
    private var startMenuWindow: StartMenuWindow?
    private var returnApplication: NSRunningApplication?

    init(configuration: VMRunConfiguration, stateRoot: URL, storageLocationStore: StorageLocationPreferenceStore,
         settings: LauncherSettingsFile, bundle: Bundle, networkService: NetworkServiceControls) {
        self.configuration = configuration
        self.stateRoot = stateRoot
        self.storageLocationStore = storageLocationStore
        self.settings = settings
        self.bundle = bundle
        self.networkService = networkService
        activationController.setDesiredPolicy(.prohibited)
    }

    func show() -> Bool {
        activationController.setDesiredPolicy(ApplicationPresentation.runningActivationPolicy)
        if let startMenuWindow, startMenuWindow.window.isVisible || startMenuWindow.window.isMiniaturized {
            startMenuWindow.bringToFront()
            NSApp.activate(ignoringOtherApps: true)
            return true
        }
        returnApplication = NSWorkspace.shared.frontmostApplication
        let window = startMenuWindow ?? makeWindow()
        startMenuWindow = window
        window.show()
        return true
    }

    func networkServiceChanged() {
        startMenuWindow?.networkServiceChanged()
    }

    func close() {
        startMenuWindow?.dismiss()
        activationController.setDesiredPolicy(.prohibited)
        returnApplication?.activate(options: [])
        returnApplication = nil
    }

    private func makeWindow() -> StartMenuWindow {
        let sharedFolderStore = SharedFolderPreferenceStore(storage: settings)
        let usbDeviceStore = USBDevicePreferenceStore(storage: settings)
        let portForwardingStore = PortForwardingPreferenceStore(storage: settings)
        let networkStore = VMNetworkPreferenceStore(storage: settings)
        let fullscreenStore = FullscreenPreferenceStore(storage: settings)
        let resourceStore = VMResourcePreferenceStore(storage: settings)
        let limits = VMResourceLimits.current
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let stateRoot = stateRoot
        let resources = bundle.resourceURL
        let followsChoice = configuration.storageRoot == nil
        let storageStatus: () -> StorageLocationMenuState = { [storageLocationStore] in
            let preference = storageLocationStore.load()
            guard followsChoice, let container = preference.containerPath,
                  StorageLocationPolicy.stateRoot(forContainer: container) == stateRoot.path else { return .defaultLocation }
            return StorageLocationMenuState.make(preference: preference, metrics: nil, homeDirectory: homeDirectory)
        }
        let window = StartMenuWindow(
            accessibilityStatus: { AXIsProcessTrusted() },
            microphoneStatus: { MicrophonePreflight.authorizationState() },
            cameraStatus: { CameraPreflight.authorizationState() },
            requestAccessibility: {
                guard !AXIsProcessTrusted() else { return }
                let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
                guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSWorkspace.shared.open(url) }
            },
            requestMicrophone: { MicrophonePreflight.requestAccess(completion: $0) },
            requestCamera: { CameraPreflight.requestAccess(completion: $0) },
            canResetStorage: false,
            storageLocation: { StorageLocationPolicy.displayPath(stateRoot.path, homeDirectory: homeDirectory) },
            storageLocationURL: { stateRoot },
            storageLocationStatus: storageStatus,
            validateStorageLocation: { _ in "Shut down Omarchy before changing its VM." },
            chooseStorageLocation: { _ in "Shut down Omarchy before changing its VM." },
            useDefaultStorageLocation: {},
            resetSettings: { [settings] in
                SharedFolderPreferenceStore(storage: settings).save(.disabled)
                USBDevicePreferenceStore(storage: settings).save(.disabled)
                try? PortForwardingPreferenceStore(storage: settings).save([])
                try? VMNetworkPreferenceStore(storage: settings).save(VMNetworkPreferences())
                FullscreenPreferenceStore(storage: settings).save(.defaults)
                VMResourcePreferenceStore(storage: settings).clear()
            },
            sharedFolderStatus: {
                SharedFolderMenuState.make(preference: sharedFolderStore.load(), homeDirectory: homeDirectory)
            },
            chooseSharedFolder: { path in
                do {
                    let canonical = try SharedFolderPolicy.validate(path, homeDirectory: homeDirectory)
                    sharedFolderStore.save(SharedFolderPreference(path: canonical, isEnabled: true))
                    return nil
                } catch {
                    return error.localizedDescription
                }
            },
            setSharedFolderEnabled: { enabled in
                var preference = sharedFolderStore.load()
                guard preference.path != nil else { return }
                preference.isEnabled = enabled
                sharedFolderStore.save(preference)
            },
            usbDeviceStatus: {
                USBDeviceMenuState.make(preference: usbDeviceStore.load(), connected: HostUSBDevices.connected(),
                                        environment: [:])
            },
            connectedUSBDevices: { HostUSBDevices.connected() },
            saveUSBDevice: { usbDeviceStore.save($0) },
            portForwardingStatus: { portForwardingStore.load() },
            savePortForwarding: { mappings in
                do { try portForwardingStore.save(mappings); return nil } catch { return error.localizedDescription }
            },
            resources: { [configuration] in
                var resources = VMRunLaunchSettings.shownResources(stored: resourceStore.load(),
                                                                   configuration: configuration, limits: limits)
                resources.diskGiB = resources.diskGiB.map { max($0, Self.minimumDiskGiB(stateRoot: stateRoot)) }
                return resources
            },
            resourceLimits: limits,
            minimumDiskGiB: { Self.minimumDiskGiB(stateRoot: stateRoot) },
            saveResources: { resourceStore.save($0) },
            networkPreferences: { networkStore.load() },
            saveNetworkPreferences: { preferences in
                do { try networkStore.save(preferences); return nil } catch { return error.localizedDescription }
            },
            networkIdentity: resources.map { resources in
                VMNetworkIdentityAccess.forLaunch(arguments: []) { arguments in
                    try VMNetworkIdentityAccess.operation(arguments, root: stateRoot, resources: resources)
                }
            } ?? .unavailable,
            networkService: networkService,
            immersiveMode: { fullscreenStore.load().isImmersive },
            setImmersiveMode: { isImmersive in
                var preferences = fullscreenStore.load()
                preferences.isImmersive = isImmersive
                fullscreenStore.save(preferences)
            },
            notchAvailable: { HostDisplayCutouts.macHasNotch() },
            usesNotch: { fullscreenStore.load().usesNotch },
            setUsesNotch: { usesNotch in
                var preferences = fullscreenStore.load()
                preferences.usesNotch = usesNotch
                fullscreenStore.save(preferences)
            },
            productName: configuration.productName,
            runsInAnotherApp: true,
            firstBootCompleted: { true },
            launch: {}
        )
        window.virtualMachineDidStart(closeSettings: { [weak self] in self?.close() })
        return window
    }

    /// The VM disk's current size: a disk never shrinks.
    private static func minimumDiskGiB(stateRoot: URL) -> Int {
        let disk = stateRoot.appendingPathComponent("shell/disk.img")
        let attributes = try? FileManager.default.attributesOfItem(atPath: disk.path)
        let bytes = (attributes?[.type] as? FileAttributeType) == .typeRegular
            ? (attributes?[.size] as? NSNumber)?.int64Value : nil
        return max(1, Int(max(0, (bytes ?? 1) - 1) / (1 << 30)) + 1)
    }
}
