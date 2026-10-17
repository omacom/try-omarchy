import SwiftUI

/// The launcher's commands. `StartMenuWindow` owns the behavior; the views
/// only forward user intent.
@MainActor
struct LauncherActions {
    var launchOrDone: () -> Void = {}
    var accessibilityAction: () -> Void = {}
    var microphoneAction: () -> Void = {}
    var cameraAction: () -> Void = {}
    var chooseSharedFolder: () -> Void = {}
    var setSharedFolderEnabled: (Bool) -> Void = { _ in }
    var chooseUSBDevice: () -> Void = {}
    var setUSBDeviceEnabled: (Bool) -> Void = { _ in }
    var configureNetwork: () -> Void = {}
    var configurePortForwarding: () -> Void = {}
    var configureResources: () -> Void = {}
    var manageStorage: () -> Void = {}
    var openStorageLocation: () -> Void = {}
    var setImmersive: (Bool) -> Void = { _ in }
    var setUsesNotch: (Bool) -> Void = { _ in }
    var setStartAutomatically: (Bool) -> Void = { _ in }
    var reset: () -> Void = {}
    var restart: () -> Void = {}
    var shutDown: () -> Void = {}
    var checkForUpdates: () -> Void = {}
}

extension LauncherPane {
    var icon: SettingIcon {
        switch self {
        case .home: .omarchy
        case .permissions: SettingIcon("hand.raised.fill", .blue)
        case .sharing: SettingIcon("folder.fill", .cyan)
        case .network: SettingIcon("network", .blue)
        case .virtualMachine: SettingIcon("cpu", .purple)
        case .startup: SettingIcon("power", .gray)
        }
    }
}

extension LauncherAttentionItem {
    var icon: SettingIcon {
        switch kind {
        case .accessibility: SettingIcon("accessibility", .blue)
        case .storage: SettingIcon("externaldrive.fill", .gray)
        case .network: SettingIcon("network", .blue)
        case .usb: SettingIcon("cable.connector", .gray)
        case .sharedFolder: SettingIcon("folder.fill", .cyan)
        }
    }
}

struct LauncherView: View {
    @Bindable var state: LauncherState
    let actions: LauncherActions

    var body: some View {
        // A plain side-by-side layout instead of NavigationSplitView: the
        // split view's divider draws a hard dark line beside the content.
        HStack(spacing: 0) {
            LauncherSidebar(state: state, actions: actions)
                .frame(width: 220)
            VStack(spacing: 0) {
                header
                pane
                    // One continuous background behind the header and panes.
                    .scrollContentBackground(.hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .disabled(state.permissionRequestInFlight)
        }
        .ignoresSafeArea(.container, edges: .top)
        .navigationTitle((state.selectedPane ?? .home).rawValue)
        .frame(minWidth: 760, minHeight: 500)
    }

    /// The pane title shares the title bar row with the window buttons, with
    /// Launch one click away from every settings pane.
    private var header: some View {
        HStack(spacing: 12) {
            Text((state.selectedPane ?? .home).rawValue)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if state.selectedPane != .home {
                Button(action: actions.launchOrDone) {
                    if state.isRunning {
                        Text("Done")
                    } else {
                        Label(state.launchTitle, systemImage: "play.fill")
                    }
                }
                .disabled(!state.launchEnabled)
                .accessibilityIdentifier("toolbar-launch-button")
            }
        }
        .padding(.horizontal, 28)
        .frame(height: 52)
    }

    @ViewBuilder private var pane: some View {
        switch state.selectedPane ?? .home {
        case .home:
            HomePane(state: state, actions: actions)
        case .permissions:
            Form { PermissionsSection(state: state, actions: actions) }.formStyle(.grouped)
        case .sharing:
            Form { SharingSection(state: state, actions: actions) }.formStyle(.grouped)
        case .network:
            Form { NetworkSection(state: state, actions: actions) }.formStyle(.grouped)
        case .virtualMachine:
            Form {
                VirtualMachineSection(state: state, actions: actions)
                ResetSection(state: state, actions: actions)
            }
            .formStyle(.grouped)
        case .startup:
            Form { StartupSection(state: state, actions: actions) }.formStyle(.grouped)
        }
    }
}

// MARK: - Sidebar

private struct LauncherSidebar: View {
    @Bindable var state: LauncherState
    let actions: LauncherActions

    var body: some View {
        List(selection: $state.selectedPane) {
            ForEach(LauncherPane.allCases) { pane in
                Label {
                    Text(pane.rawValue)
                } icon: {
                    pane.icon.environment(\.settingIconSize, 20)
                }
                .badge(pane == .home ? 0 : state.attentionCount(for: pane))
                .tag(pane)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 44) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.appVersionLabel)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(state.appVersionLabel)
                    .accessibilityIdentifier("app-version")
                Button(state.appReleaseActionTitle, action: actions.checkForUpdates)
                    .buttonStyle(.link)
                    .accessibilityIdentifier("app-release-check")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
    }
}

// MARK: - Home

private struct HomePane: View {
    @Bindable var state: LauncherState
    let actions: LauncherActions

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 22) {
                    OmarchyAppTile(size: 104)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Try Omarchy")
                            .font(.system(size: 26, weight: .bold))
                            .accessibilityAddTraits(.isHeader)
                        status
                        Text(state.guest.lines.first ?? "")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) { homeActions }
                            .padding(.top, 10)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 8)
            }

            if !state.attentionItems.isEmpty {
                Section("Needs Attention") {
                    ForEach(state.attentionItems) { item in
                        SettingRow(icon: item.icon, title: item.title, detail: [item.detail]) {
                            Button("Review…") { state.selectedPane = item.pane }
                        }
                    }
                }
            }

            Section("Quick Settings") {
                SettingRow(
                    icon: SettingIcon("arrow.up.left.and.arrow.down.right", .black),
                    title: "Immersive Mode",
                    detail: [StartMenuPresentation.immersiveDetail(isEnabled: state.immersive)]
                ) {
                    LauncherSwitch("Immersive Mode", isOn: state.immersive, set: actions.setImmersive)
                }
                SettingRow(
                    icon: SettingIcon("folder.fill", .cyan),
                    title: "Shared Folder",
                    detail: state.sharedFolder.compactDetailLines ?? [state.sharedFolder.detail]
                ) {
                    if state.sharedFolderState.path == nil {
                        Button("Choose…", action: actions.chooseSharedFolder)
                    } else {
                        LauncherSwitch(
                            "Shared Folder",
                            isOn: state.sharedFolderState.isEnabled,
                            set: actions.setSharedFolderEnabled
                        )
                    }
                }
                SettingRow(
                    icon: SettingIcon("cpu", .purple),
                    title: "Resources",
                    detail: [state.resourcesSummary]
                ) {
                    Button("Configure…", action: actions.configureResources)
                }
            }
            .disabled(!state.settingsEnabled)
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var status: some View {
        Group {
            if state.isRunning {
                if state.shutdownInProgress {
                    Text("Waiting for Omarchy to shut down. Finish saving your work inside Omarchy.")
                } else {
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 7, height: 7)
                        Text("Running · some changes apply after a restart")
                    }
                }
            } else if state.launchInProgress {
                Text(state.launchStatus)
            } else if state.resetInProgress {
                Text(state.resetPhase.buttonTitle)
            } else if state.attentionItems.isEmpty {
                Text("Ready to launch")
            } else {
                Text("Ready to launch · review \(state.attentionItems.count == 1 ? "1 item" : "\(state.attentionItems.count) items") below")
            }
        }
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var homeActions: some View {
        if state.isRunning {
            Button("Done", action: actions.launchOrDone)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!state.launchEnabled)
                .accessibilityIdentifier("launch-button")
            Button("Restart…", action: actions.restart)
                .controlSize(.large)
                .disabled(!state.runningActionsEnabled)
                .accessibilityIdentifier("restart-vm-button")
            if state.canResetStorage {
                Button("Shut Down…", action: actions.shutDown)
                    .controlSize(.large)
                    .disabled(!state.runningActionsEnabled)
                    .accessibilityIdentifier("manage-vm-button")
            }
            if state.shutdownInProgress { ProgressView().controlSize(.small) }
        } else {
            Button(action: actions.launchOrDone) {
                Label(state.launchInProgress ? "Launching…" : "Launch Omarchy", systemImage: "play.fill")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .keyboardShortcut(state.launchInProgress || state.storageMoveInProgress ? nil : .defaultAction)
            .disabled(!state.launchEnabled)
            .accessibilityLabel(state.launchTitle)
            .accessibilityIdentifier("launch-button")
            if state.launchInProgress || state.resetInProgress { ProgressView().controlSize(.small) }
        }
    }
}

/// A native switch that reports changes instead of owning the value, so a
/// refused or failed save leaves it showing the stored preference.
private struct LauncherSwitch: View {
    let title: String
    let isOn: Bool
    let set: (Bool) -> Void

    init(_ title: String, isOn: Bool, set: @escaping (Bool) -> Void) {
        self.title = title
        self.isOn = isOn
        self.set = set
    }

    var body: some View {
        Toggle(title, isOn: Binding(get: { isOn }, set: { value in
            // Leave the SwiftUI transaction before any confirmation runs modally.
            DispatchQueue.main.async { set(value) }
        }))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
    }
}

// MARK: - Permissions

private struct PermissionsSection: View {
    let state: LauncherState
    let actions: LauncherActions

    var body: some View {
        Section {
            SettingRow(
                icon: SettingIcon("accessibility", .blue),
                title: "Accessibility",
                detail: [state.accessibility.detail]
            ) {
                PermissionControl(presentation: state.accessibility, action: actions.accessibilityAction)
            }
            SettingRow(
                icon: SettingIcon("mic.fill", .orange),
                title: "Microphone",
                detail: [state.microphone.detail]
            ) {
                PermissionControl(
                    presentation: state.microphone,
                    waiting: state.microphoneRequestInFlight,
                    action: actions.microphoneAction
                )
            }
            SettingRow(
                icon: SettingIcon("camera.fill", .green),
                title: "Camera",
                detail: [state.camera.detail]
            ) {
                PermissionControl(
                    presentation: state.camera,
                    waiting: state.cameraRequestInFlight,
                    action: actions.cameraAction
                )
            }
        } footer: {
            SectionNote("Microphone and camera are optional. Change these anytime in System Settings › Privacy & Security.")
        }
    }
}

private struct PermissionControl: View {
    let presentation: StartMenuPermissionPresentation
    var waiting = false
    let action: () -> Void

    var body: some View {
        if presentation.isGranted {
            StatusLabel(text: "Allowed", symbol: "checkmark.circle.fill", color: .green)
        } else if waiting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting…").foregroundStyle(.secondary)
            }
        } else if let title = presentation.actionTitle {
            Button(title == "Open Settings" ? "Open Settings…" : title, action: action)
        } else {
            StatusLabel(text: "Unavailable", symbol: "lock.fill", color: .secondary)
        }
    }
}

// MARK: - Sharing

private struct SharingSection: View {
    let state: LauncherState
    let actions: LauncherActions

    var body: some View {
        Section {
            SettingRow(
                icon: SettingIcon("folder.fill", .cyan),
                title: "Shared Folder",
                detail: state.sharedFolderState.problem == nil
                    ? state.sharedFolder.compactDetailLines ?? [state.sharedFolder.detail] : [],
                warning: state.sharedFolderState.problem
            ) {
                Button("Choose…", action: actions.chooseSharedFolder)
                if state.sharedFolderState.path != nil {
                    LauncherSwitch(
                        "Shared Folder",
                        isOn: state.sharedFolderState.isEnabled,
                        set: actions.setSharedFolderEnabled
                    )
                }
            }

            SettingRow(
                icon: SettingIcon("cable.connector", .gray),
                title: "USB Device",
                badge: "Experimental",
                detail: state.usbDevice.compactDetailLines ?? [state.usbDevice.detail]
            ) {
                Button("Choose…", action: actions.chooseUSBDevice)
                    .disabled(!state.usbDevice.actionsEnabled)
                if state.usbDevice.toggleActionTitle != nil {
                    LauncherSwitch(
                        "USB Device",
                        isOn: state.usbDeviceState.isEnabled,
                        set: actions.setUSBDeviceEnabled
                    )
                }
            }
        } footer: {
            SectionNote("Changes apply the next time Omarchy starts.")
        }
        .disabled(!state.settingsEnabled)
    }
}

// MARK: - Network

private struct NetworkSection: View {
    let state: LauncherState
    let actions: LauncherActions

    var body: some View {
        Section {
            SettingRow(
                icon: SettingIcon("network", .blue),
                title: "Network",
                detail: [state.networkDetail],
                warning: state.networkWarning
            ) {
                Button("Configure…", action: actions.configureNetwork)
            }

            SettingRow(
                icon: SettingIcon("arrow.left.arrow.right", .indigo),
                title: "Port Forwarding",
                detail: state.networkIsBridged
                    ? ["Inactive in bridged mode. Your saved rules are kept."]
                    : state.portForwarding.compactDetailLines ?? [state.portForwarding.detail]
            ) {
                if !state.networkIsBridged, state.portCount > 0 {
                    Text(state.portCount == 1 ? "1 Port" : "\(state.portCount) Ports")
                        .foregroundStyle(.secondary)
                }
                Button("Configure…", action: actions.configurePortForwarding)
                    .disabled(state.networkIsBridged)
            }
        } footer: {
            SectionNote("Changes apply the next time Omarchy starts.")
        }
        .disabled(!state.settingsEnabled)
    }
}

// MARK: - Virtual machine

private struct VirtualMachineSection: View {
    let state: LauncherState
    let actions: LauncherActions

    var body: some View {
        Section {
            SettingRow(
                icon: SettingIcon("cpu", .purple),
                title: "Resources",
                detail: [state.resourcesSummary]
            ) {
                if state.resourcesAreDefault {
                    Text("Default").foregroundStyle(.secondary)
                }
                Button("Configure…", action: actions.configureResources)
                    .disabled(!state.settingsEnabled)
            }

            if let storage = state.storage {
                SettingRow(
                    icon: SettingIcon(storage.isExternal ? "externaldrive.fill" : "internaldrive.fill", .gray),
                    title: "Selected VM",
                    detail: storage.lines,
                    warning: storage.problem
                ) {
                    if storage.canOpenInFinder {
                        Button(action: actions.openStorageLocation) {
                            Image(systemName: "arrow.forward.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Show in Finder")
                        .accessibilityLabel("Open in Finder")
                    }
                    Button("Manage…", action: actions.manageStorage)
                        .disabled(!state.manageStorageEnabled)
                }
            }

            // Omarchy updates itself inside the VM (omarchy update); this row
            // only reports what the guest last said about its versions.
            SettingRow(icon: .omarchy, title: "Omarchy", detail: state.guest.lines) {
                if state.guestReported {
                    if state.guest.isCurrent {
                        StatusLabel(text: "Up to Date", symbol: "checkmark.circle.fill", color: .green)
                    } else {
                        StatusLabel(text: "Update Pending", symbol: "arrow.down.circle.fill", color: .orange)
                    }
                }
            }
        } footer: {
            SectionNote("Resource changes apply the next time Omarchy starts. Omarchy updates itself inside the VM with omarchy update.")
        }
    }
}

// MARK: - Startup

private struct StartupSection: View {
    let state: LauncherState
    let actions: LauncherActions

    var body: some View {
        Section {
            SettingRow(
                icon: SettingIcon("arrow.up.left.and.arrow.down.right", .black),
                title: "Immersive Mode",
                detail: [StartMenuPresentation.immersiveDetail(isEnabled: state.immersive)]
            ) {
                LauncherSwitch("Immersive Mode", isOn: state.immersive, set: actions.setImmersive)
            }

            if state.notchAvailable {
                SettingRow(
                    icon: SettingIcon("macbook", .gray),
                    title: "Camera Notch",
                    detail: [StartMenuPresentation.notchDetail(isEnabled: state.usesNotch)]
                ) {
                    LauncherSwitch("Camera Notch", isOn: state.usesNotch, set: actions.setUsesNotch)
                }
            }

            SettingRow(
                icon: SettingIcon("forward.fill", .orange),
                title: "Skip Launcher",
                detail: [state.isRunning
                    ? "Launch Omarchy with your saved settings. Open settings anytime from Omarchy’s Setup menu."
                    : "Launch Omarchy with your saved settings. Hold Option while opening the app to show the launcher."]
            ) {
                LauncherSwitch("Skip Launcher", isOn: state.startAutomatically, set: actions.setStartAutomatically)
            }
        }
        .disabled(!state.settingsEnabled)
    }
}

// MARK: - Reset

private struct ResetSection: View {
    let state: LauncherState
    let actions: LauncherActions

    var body: some View {
        Section {
            SettingRow(
                icon: SettingIcon("arrow.counterclockwise", .red),
                title: "Reset Omarchy",
                detail: [state.isRunning
                    ? "Shut down Omarchy to change the VM location or reset it to factory settings."
                    : (state.canResetStorage
                        ? "Permanently erase this VM. The next launch creates a fresh one in the same folder."
                        : "Reset is unavailable for a disposable VM.")]
            ) {
                if state.resetInProgress {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(state.resetPhase.buttonTitle).foregroundStyle(.secondary)
                    }
                } else if state.isRunning {
                    if state.canResetStorage {
                        Button("Shut Down…", action: actions.shutDown)
                            .disabled(!state.runningActionsEnabled)
                    }
                } else {
                    Button("Reset…", role: .destructive, action: actions.reset)
                        .foregroundStyle(.red)
                        .disabled(!state.resetEnabled)
                        .help(state.canResetStorage
                            ? "Permanently erase this VM and create a fresh one in the same folder"
                            : "Reset is unavailable for a disposable VM")
                        .accessibilityIdentifier("reset-button")
                }
            }
        }
    }
}
