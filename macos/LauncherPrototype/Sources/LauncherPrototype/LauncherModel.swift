import Observation
import SwiftUI

enum PreviewAppearance: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: Self { self }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum PreviewPreset: String, CaseIterable, Identifiable {
    case fresh = "Fresh Install"
    case configured = "Configured"
    case attention = "Needs Attention"

    var id: Self { self }
}

enum LaunchPhase: String, CaseIterable {
    case checking = "Checking VM…"
    case preparing = "Preparing image…"
    case finishing = "Finishing setup…"
    case starting = "Starting Omarchy…"
}

enum ResetPhase: String, CaseIterable {
    case checking = "Checking VM…"
    case deleting = "Deleting VM…"
    case finishing = "Finishing reset…"
}

enum RunState: Equatable {
    case ready
    case launching(LaunchPhase)
    case running
    case shuttingDown
    case resetting(ResetPhase)
}

enum PreviewRunState: String, CaseIterable, Identifiable {
    case ready = "Ready"
    case launching = "Launching"
    case running = "Running"
    case shuttingDown = "Shutting Down"
    case resetting = "Resetting"

    var id: Self { self }
}

enum PermissionState: String, CaseIterable, Identifiable {
    case notDetermined = "Not Determined"
    case waiting = "Waiting for Prompt"
    case authorized = "Allowed"
    case denied = "Denied"
    case restricted = "Restricted"

    var id: Self { self }
}

enum NetworkMode: String, CaseIterable, Identifiable {
    case nat = "Shared connection (NAT)"
    case bridged = "Bridged, own LAN address"

    var id: Self { self }
}

enum PortProtocol: String, CaseIterable, Identifiable {
    case tcp = "TCP"
    case udp = "UDP"

    var id: Self { self }
}

struct PortMapping: Identifiable, Equatable {
    var id = UUID()
    var proto: PortProtocol = .tcp
    var hostPort: Int?
    var guestPort: Int?
}

struct BridgeInterface: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let title: String
}

enum LauncherSheet: String, Identifiable {
    case resources, network, ports, usb, storage

    var id: Self { self }
}

enum LauncherAlert: Identifiable {
    case restart, shutDown, skipLauncher, resetFinished

    var id: Self { self }
}

/// Mock state for the visual prototype. Every value the real launcher reads
/// from the controller lives here so each state can be previewed.
@Observable
final class LauncherModel {
    var appearance = PreviewAppearance.system
    var preset = PreviewPreset.configured
    var runState = RunState.ready

    var accessibility = PermissionState.notDetermined
    var microphone = PermissionState.notDetermined
    var camera = PermissionState.notDetermined

    var sharedFolderPath: String?
    var sharedFolderEnabled = false
    var usbDevice: String?
    var usbEnabled = false
    var usbConnected = true
    let connectedUSBDevices = ["YubiKey 5C NFC", "Keychron K3 Pro", "Arduino Uno R4"]

    var networkMode = NetworkMode.nat
    var bridgeInterface = "en0"
    var bridgeAvailable = true
    var helperInstalled = true
    var bridgedSSH = false
    var macAddress = "52:54:00:3a:7c:91"
    let interfaces = [
        BridgeInterface(name: "en0", title: "Wi-Fi (en0)"),
        BridgeInterface(name: "en7", title: "Thunderbolt Ethernet (en7)"),
    ]

    var ports: [PortMapping] = []

    var cores = 4
    var memoryGiB = 8
    var diskGiB: Int?
    let defaultCores = 4
    let defaultMemoryGiB = 8
    let maximumCores = 10
    let memoryChoicesGiB = [4, 6, 8, 12, 16, 24]
    let minimumDiskGiB = 64

    var storagePath = "~/Library/Application Support/Try Omarchy"
    var storageIsDefault = true
    var storageVolume: String?
    var storageExternal = false
    var storageProblem: String?
    var storageMoveProgress: Double?

    var guestReported = true
    var guestLines = ["Omarchy 3.1.2 · stable", "Integrations 0.9.4"]
    var guestCurrent = true

    var immersive = true
    var skipLauncher = false

    let appVersion = "Version 2.3.0"
    var updateStatus = "Try Omarchy 2.3.0 is the latest version."
    var checkingForUpdates = false
    var automaticUpdateChecks = true

    var activeSheet: LauncherSheet?
    var activeAlert: LauncherAlert?

    init(arguments: [String] = CommandLine.arguments) {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        applyPreset(PreviewPreset.allCases.first { $0.rawValue == value("--preset") } ?? .configured)
        if let appearance = PreviewAppearance.allCases.first(where: { $0.rawValue.lowercased() == value("--appearance") }) {
            self.appearance = appearance
        }
        if let state = PreviewRunState.allCases.first(where: { $0.rawValue == value("--state") }) {
            previewRunState = state
        }
        activeSheet = value("--sheet").flatMap(LauncherSheet.init(rawValue:))
    }

    // MARK: Derived state

    var isRunning: Bool { runState == .running || runState == .shuttingDown }

    var isLaunching: Bool {
        if case .launching = runState { true } else { false }
    }

    var isResetting: Bool {
        if case .resetting = runState { true } else { false }
    }

    var permissionPromptOpen: Bool { microphone == .waiting || camera == .waiting }

    /// Mirrors `controlsBusy` in the AppKit launcher.
    var controlsBusy: Bool {
        isLaunching || runState == .shuttingDown || storageMoveProgress != nil
    }

    var prelaunchLocked: Bool { controlsBusy || isRunning }

    var settingsLocked: Bool { controlsBusy || isResetting }

    var resourceSummary: String {
        "\(cores) cores · \(memoryGiB) GiB memory" + (diskGiB.map { " · \($0) GiB disk" } ?? "")
    }

    var resourcesAreDefault: Bool {
        cores == defaultCores && memoryGiB == defaultMemoryGiB && diskGiB == nil
    }

    var sharedFolderGuestPath: String? {
        sharedFolderPath.map { "~/" + ($0 as NSString).lastPathComponent }
    }

    var activePorts: [PortMapping] {
        ports.filter { $0.hostPort != nil && $0.guestPort != nil }
    }

    var previewRunState: PreviewRunState {
        get {
            switch runState {
            case .ready: .ready
            case .launching: .launching
            case .running: .running
            case .shuttingDown: .shuttingDown
            case .resetting: .resetting
            }
        }
        set {
            launchTask?.cancel()
            switch newValue {
            case .ready: runState = .ready
            case .launching: runState = .launching(.preparing)
            case .running: runState = .running
            case .shuttingDown: runState = .shuttingDown
            case .resetting: runState = .resetting(.deleting)
            }
        }
    }

    // MARK: Presets

    func applyPreset(_ preset: PreviewPreset) {
        self.preset = preset
        switch preset {
        case .fresh:
            accessibility = .notDetermined
            microphone = .notDetermined
            camera = .notDetermined
            sharedFolderPath = nil
            sharedFolderEnabled = false
            usbDevice = nil
            usbEnabled = false
            usbConnected = true
            networkMode = .nat
            bridgeAvailable = true
            helperInstalled = false
            ports = []
            cores = defaultCores
            memoryGiB = defaultMemoryGiB
            diskGiB = nil
            storagePath = "~/Library/Application Support/Try Omarchy"
            storageIsDefault = true
            storageVolume = nil
            storageExternal = false
            storageProblem = nil
            guestReported = false
            guestLines = ["Versions appear after Omarchy starts"]
            guestCurrent = true
            immersive = true
            skipLauncher = false
        case .configured:
            accessibility = .authorized
            microphone = .authorized
            camera = .notDetermined
            sharedFolderPath = "~/Code/projects"
            sharedFolderEnabled = true
            usbDevice = nil
            usbEnabled = false
            usbConnected = true
            networkMode = .nat
            bridgeAvailable = true
            helperInstalled = true
            ports = [
                PortMapping(proto: .tcp, hostPort: 8080, guestPort: 3000),
                PortMapping(proto: .tcp, hostPort: 2222, guestPort: 22),
            ]
            cores = 6
            memoryGiB = 12
            diskGiB = 128
            storagePath = "/Volumes/Studio/Omarchy"
            storageIsDefault = false
            storageVolume = "Studio"
            storageExternal = true
            storageProblem = nil
            guestReported = true
            guestLines = ["Omarchy 3.1.2 · stable", "Integrations 0.9.4"]
            guestCurrent = true
            immersive = true
            skipLauncher = false
        case .attention:
            accessibility = .notDetermined
            microphone = .denied
            camera = .restricted
            sharedFolderPath = "~/Documents/Shared"
            sharedFolderEnabled = false
            usbDevice = "YubiKey 5C NFC"
            usbEnabled = true
            usbConnected = false
            networkMode = .bridged
            bridgeInterface = "en7"
            bridgeAvailable = false
            helperInstalled = false
            ports = [PortMapping(proto: .udp, hostPort: 5353, guestPort: 5353)]
            cores = defaultCores
            memoryGiB = defaultMemoryGiB
            diskGiB = nil
            storagePath = "/Volumes/Archive/Omarchy"
            storageIsDefault = false
            storageVolume = "Archive"
            storageExternal = true
            storageProblem = "The drive that holds this VM is not connected"
            guestReported = true
            guestLines = ["Omarchy 3.1.0 · stable", "Integrations 0.9.2 → 0.9.4 next launch"]
            guestCurrent = false
            immersive = false
            skipLauncher = true
        }
    }

    // MARK: Simulated actions

    private var launchTask: Task<Void, Never>?

    func launch() {
        guard !prelaunchLocked, !isResetting, !permissionPromptOpen else { return }
        launchTask?.cancel()
        launchTask = Task { @MainActor in
            for phase in LaunchPhase.allCases {
                runState = .launching(phase)
                try? await Task.sleep(for: .milliseconds(900))
                if Task.isCancelled { return }
            }
            runState = .running
            guestReported = true
            if guestLines.count == 1 { guestLines = ["Omarchy 3.1.2 · stable", "Integrations 0.9.4"] }
        }
    }

    func shutDown(thenRestart: Bool) {
        launchTask?.cancel()
        runState = .shuttingDown
        launchTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            runState = .ready
            if thenRestart { launch() }
        }
    }

    func reset() {
        launchTask?.cancel()
        launchTask = Task { @MainActor in
            for phase in ResetPhase.allCases {
                runState = .resetting(phase)
                try? await Task.sleep(for: .milliseconds(900))
                if Task.isCancelled { return }
            }
            runState = .ready
            guestReported = false
            guestLines = ["Versions appear after Omarchy starts"]
            activeAlert = .resetFinished
        }
    }

    func request(_ permission: ReferenceWritableKeyPath<LauncherModel, PermissionState>) {
        self[keyPath: permission] = .waiting
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1400))
            self[keyPath: permission] = .authorized
        }
    }

    func checkForUpdates() {
        checkingForUpdates = true
        updateStatus = "Checking for updates…"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            checkingForUpdates = false
            updateStatus = "Try Omarchy 2.3.0 is the latest version."
        }
    }

    func moveStorage() {
        storageMoveProgress = 0
        Task { @MainActor in
            while let progress = storageMoveProgress, progress < 1 {
                try? await Task.sleep(for: .milliseconds(80))
                storageMoveProgress = min(1, progress + 0.02)
            }
            storageMoveProgress = nil
            storagePath = "/Volumes/Studio/Omarchy 2"
            storageIsDefault = false
            storageVolume = "Studio"
            storageExternal = true
            storageProblem = nil
        }
    }
}
