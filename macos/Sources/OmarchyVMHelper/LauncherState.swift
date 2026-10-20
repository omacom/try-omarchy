import Foundation
import Observation

enum LauncherPane: String, CaseIterable, Identifiable {
    case home = "Home"
    case permissions = "Permissions"
    case sharing = "Sharing"
    case network = "Network"
    case virtualMachine = "Virtual Machine"
    case startup = "Startup"

    var id: Self { self }
}

/// A Mac permission Omarchy works best with. Home asks for the unanswered
/// ones, and the first launch offers them once more.
enum LauncherPermission: String, CaseIterable, Identifiable {
    case accessibility, microphone, camera

    var id: Self { self }
}

/// Something worth fixing before a launch. Home lists these and the sidebar
/// badges the pane that fixes each one.
struct LauncherAttentionItem: Identifiable, Equatable {
    enum Kind: String {
        case storage, network, usb, sharedFolder
    }

    let kind: Kind
    let title: String
    let detail: String

    var id: Kind { kind }

    var pane: LauncherPane {
        switch kind {
        case .storage: .virtualMachine
        case .network: .network
        case .usb, .sharedFolder: .sharing
        }
    }
}

struct LauncherStorageSummary: Equatable {
    let lines: [String]
    let problem: String?
    let isDefault: Bool
    let isExternal: Bool
    let canOpenInFinder: Bool
    let isEnvironmentOverride: Bool
}

/// Everything the launcher shows, refreshed from the controller by
/// `StartMenuWindow`. Keeping it free of views keeps launcher rules testable
/// without relying on SwiftUI layout.
@MainActor
@Observable
final class LauncherState {
    var selectedPane: LauncherPane? = .home

    // MARK: Lifecycle

    var isRunning = false
    var launchInProgress = false
    var launchPhase = VMLaunchPhase.checking
    /// Set while the factory image downloads, before the launcher runs.
    var launchDownload: FactoryDownloadProgress?
    var resetInProgress = false
    var resetPhase = VMResetPhase.checking
    var shutdownInProgress = false
    var storageMoveInProgress = false
    var storageEditorOpen = false
    var automaticStartupConfirmationInProgress = false
    var microphoneRequestInFlight = false
    var cameraRequestInFlight = false
    var canResetStorage = true

    // MARK: Settings

    var accessibility = StartMenuPermissionPresentation(detail: "", isGranted: false, actionTitle: nil, action: nil)
    var microphone = StartMenuPermissionPresentation(detail: "", isGranted: false, actionTitle: nil, action: nil)
    var camera = StartMenuPermissionPresentation(detail: "", isGranted: false, actionTitle: nil, action: nil)

    var sharedFolder = StartMenuPresentation.sharedFolder(state: .disabled)
    var sharedFolderState = SharedFolderMenuState.disabled
    var usbDevice = StartMenuPresentation.usbDevice(state: .disabled)
    var usbDeviceState = USBDeviceMenuState.disabled

    var networkIsBridged = false
    var networkDetail = "Shared (NAT) · Uses your Mac’s connection"
    var networkWarning: String?
    var portForwarding = StartMenuPresentation.portForwarding(mappings: [])
    var portCount = 0

    var resourcesSummary = ""
    var resourcesAreDefault = true
    var storage: LauncherStorageSummary?
    var guest = ShellGuestPresentation.make(record: nil, bundledPackage: nil)
    var guestReported = false

    var permissionPromptPresented = false

    var immersive = true
    /// Only a MacBook with a camera notch has the strip to use.
    var notchAvailable = false
    var usesNotch = true
    var startAutomatically = false

    var appVersionLabel = ""
    var appReleaseActionTitle = "Check for Updates…"

    // MARK: Derived rules

    var permissionRequestInFlight: Bool { microphoneRequestInFlight || cameraRequestInFlight }

    /// Work that must finish before settings can change or the VM can start.
    var controlsBusy: Bool {
        launchInProgress || shutdownInProgress || automaticStartupConfirmationInProgress
            || storageMoveInProgress || storageEditorOpen
    }

    var prelaunchLocked: Bool { controlsBusy || isRunning }

    /// A system permission prompt freezes every control until it answers.
    var settingsEnabled: Bool { !controlsBusy && !resetInProgress && !permissionRequestInFlight }

    var launchEnabled: Bool {
        guard !permissionRequestInFlight, !storageEditorOpen, !storageMoveInProgress else { return false }
        return isRunning || (!launchInProgress && !resetInProgress)
    }

    var launchStatus: String { launchDownload?.title ?? launchPhase.buttonTitle }

    var launchTitle: String {
        if isRunning { return "Done" }
        return launchInProgress ? launchStatus : "Launch Omarchy"
    }

    var resetEnabled: Bool {
        canResetStorage && !prelaunchLocked && !resetInProgress && !permissionRequestInFlight
    }

    var runningActionsEnabled: Bool { !controlsBusy && !permissionRequestInFlight }

    var manageStorageEnabled: Bool {
        canResetStorage && !prelaunchLocked && !resetInProgress && !permissionRequestInFlight
            && storage?.isEnvironmentOverride == false
    }

    /// Permissions still waiting for an answer. macOS never reports a
    /// declined Accessibility request, so that one stays until it is allowed.
    var pendingPermissions: [LauncherPermission] {
        var permissions: [LauncherPermission] = []
        if !accessibility.isGranted { permissions.append(.accessibility) }
        if microphone.action == .request { permissions.append(.microphone) }
        if camera.action == .request { permissions.append(.camera) }
        return permissions
    }

    var attentionItems: [LauncherAttentionItem] {
        var items: [LauncherAttentionItem] = []
        if let problem = storage?.problem {
            items.append(LauncherAttentionItem(kind: .storage, title: "Selected VM unavailable", detail: problem))
        }
        if let networkWarning {
            items.append(LauncherAttentionItem(kind: .network, title: "Networking", detail: networkWarning))
        }
        if let problem = sharedFolderState.problem {
            items.append(LauncherAttentionItem(kind: .sharedFolder, title: "Shared folder", detail: problem))
        }
        if usbDeviceState.device != nil, usbDeviceState.isEnabled,
           !usbDeviceState.isConnected || usbDeviceState.hasUnsafeLocation {
            items.append(LauncherAttentionItem(
                kind: .usb,
                title: "USB device",
                detail: usbDeviceState.hasUnsafeLocation
                    ? "Cannot safely select this USB port. Omarchy will start without it."
                    : "Not connected at the selected USB port. Omarchy will start without it."
            ))
        }
        return items
    }

    func attentionCount(for pane: LauncherPane) -> Int {
        attentionItems.filter { $0.pane == pane }.count
            + (pane == .permissions ? pendingPermissions.count : 0)
    }

    // MARK: Builders

    static func storageSummary(
        path: String,
        status: StorageLocationMenuState,
        moving: Bool,
        canOpen: Bool
    ) -> LauncherStorageSummary {
        var lines = [path]
        if moving {
            lines = ["Copying and verifying your VM… Original retained."]
        } else if status.problem == nil, !status.isDefault {
            let volume = [status.volumeName, status.isExternal ? "External drive" : nil]
                .compactMap { $0 }
                .joined(separator: " · ")
            // Say so when the environment picked this workspace, otherwise the
            // row reads as the user's own choice while Manage stays disabled.
            if let second = status.isEnvironmentOverride
                ? "Set by \(StorageLocationPolicy.environmentKey)"
                : status.warning ?? (volume.isEmpty ? nil : volume) {
                lines.append(second)
            }
        }
        return LauncherStorageSummary(
            lines: lines,
            problem: moving ? nil : status.problem,
            isDefault: status.isDefault,
            isExternal: status.isExternal,
            canOpenInFinder: canOpen && status.problem == nil && !moving,
            isEnvironmentOverride: status.isEnvironmentOverride
        )
    }

    static func networkSummary(
        _ network: VMNetworkPreferences,
        bridgeAvailable: Bool,
        serviceEnabled: Bool
    ) -> (detail: String, warning: String?) {
        guard network.mode == .bridged else {
            return ("Shared (NAT) · Uses your Mac’s connection", nil)
        }
        let warning = !bridgeAvailable
            ? "Adapter unavailable — Omarchy will start offline"
            : (serviceEnabled ? nil : "Networking helper setup required")
        return ("Bridged via \(network.interface)", warning)
    }
}
