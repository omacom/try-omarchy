import Foundation

enum StartMenuPermissionAction: Equatable {
    case request
    case openSettings
}

struct StartMenuPermissionPresentation: Equatable {
    let detail: String
    let isGranted: Bool
    let actionTitle: String?
    let action: StartMenuPermissionAction?
}

struct StartMenuSharedFolderPresentation: Equatable {
    let detail: String
    let compactDetailLines: [String]?
    let isGranted: Bool
    let toggleActionTitle: String?
}

struct StartMenuMemoryPresentation: Equatable {
    let detail: String
    /// The MiB value behind each popup entry, in display order.
    let choicesMiB: [Int]
    let choiceTitles: [String]
    let selectedIndex: Int
    /// False when this Mac's RAM fits only the default, so the popup renders
    /// disabled rather than offering a single-item "choice".
    let isAdjustable: Bool
}

struct StartMenuUSBDevicePresentation: Equatable {
    let detail: String
    let compactDetailLines: [String]?
    let isGranted: Bool
    let toggleActionTitle: String?
    /// False while the environment owns the choice, so the buttons that would
    /// change it render disabled rather than quietly doing nothing.
    let actionsEnabled: Bool
}

struct StartMenuPortForwardingPresentation: Equatable {
    let detail: String
    let compactDetailLines: [String]?
    let isGranted: Bool
    let grantedStatusLabel: String
}

struct StartMenuLanguagePresentation: Equatable {
    let detail: String
    /// True once a non-default guest locale is selected. Only affects the
    /// row's status dot color, mirroring how `sharedFolder` and
    /// `portForwarding` treat "the optional setting is turned on."
    let isNonDefault: Bool
    let statusLabel: String
    let actionTitle: String
}

/// Pure presentation rules for the start menu. Keeping user-visible state out
/// of AppKit makes the important behavior testable without relying on window
/// positions, font metrics, run-loop timing, or the current display size.
enum StartMenuPresentation {
    static func resources(_ resources: VMResources) -> String {
        "\(resources.cpuCount) processor cores · \(resources.memoryGiB) GiB memory"
            + (resources.diskGiB.map { " · \($0) GiB disk" } ?? "")
    }

    static let incompatibleWorkspaceDetail = "The saved VM uses a storage or boot format this version can’t use, or its data folder contains multiple saved VMs. Reset Omarchy to create a compatible VM. Resetting permanently erases everything in the VM."

    static let bootRecoveryConfirmationTitle = "Prepare this saved VM once?"
    static let bootRecoveryConfirmationDetail = """
        Try Omarchy found an existing VM from an earlier app version. Before it starts, Try Omarchy will run a one-time, read-only recovery to pair that VM with its own kernel and startup files. The saved disk and all of its data remain intact.

        The factory image bundled with this app is ignored for this VM. Continuing does not reset the VM, upgrade Omarchy, or install system updates.
        """

    static func microphone(
        state: MicrophoneAuthorizationState,
        requestInFlight: Bool
    ) -> StartMenuPermissionPresentation {
        switch state {
        case .authorized:
            StartMenuPermissionPresentation(
                detail: "Apps in Omarchy can record from your Mac microphone.",
                isGranted: true,
                actionTitle: nil,
                action: nil
            )
        case .notDetermined:
            StartMenuPermissionPresentation(
                detail: "Optional. Speaker playback works without microphone access.",
                isGranted: false,
                actionTitle: requestInFlight ? "Waiting…" : "Allow…",
                action: .request
            )
        case .denied:
            StartMenuPermissionPresentation(
                detail: "Recording is off. Speaker playback will still work.",
                isGranted: false,
                actionTitle: "Open Settings",
                action: .openSettings
            )
        case .restricted:
            StartMenuPermissionPresentation(
                detail: "Recording is unavailable because of this Mac’s policy.",
                isGranted: false,
                actionTitle: nil,
                action: nil
            )
        }
    }

    static func camera(
        state: CameraAuthorizationState,
        requestInFlight: Bool
    ) -> StartMenuPermissionPresentation {
        switch state {
        case .authorized:
            StartMenuPermissionPresentation(
                detail: "Apps in Omarchy can use your Mac camera while they are recording.",
                isGranted: true,
                actionTitle: nil,
                action: nil
            )
        case .notDetermined:
            StartMenuPermissionPresentation(
                detail: "Optional. The camera turns on only while an Omarchy app uses it.",
                isGranted: false,
                actionTitle: requestInFlight ? "Waiting…" : "Allow…",
                action: .request
            )
        case .denied:
            StartMenuPermissionPresentation(
                detail: "The Mac camera is off inside Omarchy.",
                isGranted: false,
                actionTitle: "Open Settings",
                action: .openSettings
            )
        case .restricted:
            StartMenuPermissionPresentation(
                detail: "Camera access is unavailable because of this Mac’s policy.",
                isGranted: false,
                actionTitle: nil,
                action: nil
            )
        }
    }

    static func sharedFolder(
        state: SharedFolderMenuState
    ) -> StartMenuSharedFolderPresentation {
        let detail: String
        let compactDetailLines: [String]?
        if let problem = state.problem {
            detail = problem
            compactDetailLines = nil
        } else if let displayPath = state.displayPath, state.isEnabled {
            let guestPath = "~/\(SharedFolderPolicy.guestLinkName(state.path ?? displayPath))"
            detail = "Mac folder: \(displayPath). In Omarchy: \(guestPath)."
            compactDetailLines = [
                "Mac folder: \(displayPath)",
                "In Omarchy: \(guestPath)",
            ]
        } else if let displayPath = state.displayPath {
            detail = "Mac folder: \(displayPath). In Omarchy: Off."
            compactDetailLines = [
                "Mac folder: \(displayPath)",
                "In Omarchy: Off",
            ]
        } else {
            detail = "Optional. Pick a Mac folder to use inside Omarchy under the same name."
            compactDetailLines = nil
        }

        return StartMenuSharedFolderPresentation(
            detail: detail,
            compactDetailLines: compactDetailLines,
            isGranted: state.isEnabled && state.problem == nil,
            toggleActionTitle: state.path == nil ? nil : (state.isEnabled ? "Turn Off" : "Turn On")
        )
    }

    static func usbDevice(
        state: USBDeviceMenuState
    ) -> StartMenuUSBDevicePresentation {
        if let override = state.environmentOverride {
            return StartMenuUSBDevicePresentation(
                detail: "Set by \(USBPassthroughPolicy.environmentKey): \(override)",
                compactDetailLines: [
                    "Set by \(USBPassthroughPolicy.environmentKey)",
                    override,
                ],
                isGranted: true,
                toggleActionTitle: nil,
                actionsEnabled: false
            )
        }
        guard let device = state.device else {
            return StartMenuUSBDevicePresentation(
                detail: "Optional. Pass one connected Mac USB device to Omarchy. macOS keeps most devices for itself.",
                compactDetailLines: nil,
                isGranted: false,
                toggleActionTitle: nil,
                actionsEnabled: true
            )
        }
        let detail: String
        let compactDetailLines: [String]
        if !state.isEnabled {
            detail = "Mac device: \(device.displayName). In Omarchy: Off."
            compactDetailLines = [
                "Mac device: \(device.displayName)",
                "In Omarchy: Off",
            ]
        } else if state.isAmbiguous {
            detail = "\(device.displayName) has an identical twin plugged in that Omarchy cannot tell apart. Omarchy will start without either; unplug one."
            compactDetailLines = [
                "Identical \(device.displayName) plugged in twice",
                "Unplug one; Omarchy will start without it",
            ]
        } else if state.isConnected {
            detail = "Mac device: \(device.displayName). It appears in Omarchy, but macOS keeps its data."
            compactDetailLines = [
                "Mac device: \(device.displayName)",
                "Appears in Omarchy; macOS keeps its data",
            ]
        } else {
            detail = "\(device.displayName) is not plugged in. Omarchy will start without it."
            compactDetailLines = [
                "\(device.displayName) is not plugged in",
                "Omarchy will start without it",
            ]
        }
        return StartMenuUSBDevicePresentation(
            detail: detail,
            compactDetailLines: compactDetailLines,
            isGranted: state.isEnabled && state.isConnected && !state.isAmbiguous,
            toggleActionTitle: state.isEnabled ? "Turn Off" : "Turn On",
            actionsEnabled: true
        )
    }

    static func portForwarding(
        mappings: [PortForwardMapping]
    ) -> StartMenuPortForwardingPresentation {
        if mappings.isEmpty {
            return StartMenuPortForwardingPresentation(
                detail: "Optional. Reach services running in Omarchy at localhost on this Mac.",
                compactDetailLines: nil,
                isGranted: false,
                grantedStatusLabel: "●  0 Ports"
            )
        }
        if mappings.count == 1, let mapping = mappings.first {
            return StartMenuPortForwardingPresentation(
                detail: "localhost:\(mapping.hostPort) → "
                    + "Omarchy:\(mapping.guestPort) · \(mapping.protocol.displayName)",
                compactDetailLines: [
                    "Mac: localhost:\(mapping.hostPort)",
                    "Omarchy: port \(mapping.guestPort) · \(mapping.protocol.displayName)",
                ],
                isGranted: true,
                grantedStatusLabel: "●  1 Port"
            )
        }
        return StartMenuPortForwardingPresentation(
            detail: "\(mappings.count) localhost mappings. Available only on this Mac.",
            compactDetailLines: [
                "\(mappings.count) localhost mappings",
                "Available only on this Mac",
            ],
            isGranted: true,
            grantedStatusLabel: "●  \(mappings.count) Ports"
        )
    }

    static func memory(
        preferredMiB: Int,
        hostMemoryMiB: Int
    ) -> StartMenuMemoryPresentation {
        let choices = MemoryPolicy.allowedChoicesMiB(hostMemoryMiB: hostMemoryMiB)
        let selected = MemoryPolicy.resolvedMemoryMiB(
            preferredMiB: preferredMiB,
            hostMemoryMiB: hostMemoryMiB
        )
        let titles = choices.map { choice in
            MemoryPolicy.choiceTitle(memoryMiB: choice, hostMemoryMiB: hostMemoryMiB)
        }
        let isAdjustable = choices.count > 1
        return StartMenuMemoryPresentation(
            detail: isAdjustable
                ? "Higher allocations may affect macOS performance. Applies on the next launch."
                : "This Mac’s memory fits the \(MemoryPolicy.displayLabel(memoryMiB: MemoryPolicy.defaultMemoryMiB)) default.",
            choicesMiB: choices,
            choiceTitles: titles,
            selectedIndex: choices.firstIndex(of: selected) ?? 0,
            isAdjustable: isAdjustable
        )
    }

    static func immersiveDetail(isEnabled: Bool) -> String {
        isEnabled
            ? "Omarchy opens Full Screen with the Mac menu bar and Dock hidden."
            : "Omarchy opens in a window with the Mac menu bar and Dock available."
    }

    static func language(state: LanguageMenuState) -> StartMenuLanguagePresentation {
        guard state.supportsSelection else {
            return StartMenuLanguagePresentation(
                detail: "This saved VM does not support language selection. Reset Omarchy to use it; reset erases the VM’s data.",
                isNonDefault: false,
                statusLabel: "○  Requires reset",
                actionTitle: "Language unavailable"
            )
        }
        guard let selected = state.selectedLocale else {
            return StartMenuLanguagePresentation(
                detail: "Omarchy boots in English, the guest’s default language.",
                isNonDefault: false,
                statusLabel: "○  English",
                actionTitle: "Switch to \(GuestLocaleCatalog.traditionalChinese.displayName)"
            )
        }
        return StartMenuLanguagePresentation(
            detail: "Omarchy boots in \(selected.displayName).",
            isNonDefault: true,
            statusLabel: "●  \(selected.displayName)",
            actionTitle: "Use English (Default)"
        )
    }
}
