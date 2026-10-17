import AppKit
import SwiftUI

enum LauncherPane: String, CaseIterable, Identifiable {
    case home = "Home"
    case permissions = "Permissions"
    case sharing = "Sharing"
    case network = "Network"
    case virtualMachine = "Virtual Machine"
    case startup = "Startup"

    var id: Self { self }

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

/// Something the user should look at before launching, shown on Home and as a
/// sidebar badge on the pane that fixes it.
struct AttentionItem: Identifiable {
    let id: String
    let icon: SettingIcon
    let title: String
    let detail: String
    let pane: LauncherPane
}

extension LauncherModel {
    var attentionItems: [AttentionItem] {
        var items: [AttentionItem] = []
        if accessibility != .authorized {
            items.append(AttentionItem(
                id: "accessibility", icon: SettingIcon("accessibility", .blue),
                title: "Allow Accessibility",
                detail: "Needed for Super shortcuts and the native keyboard experience.",
                pane: .permissions
            ))
        }
        if let storageProblem {
            items.append(AttentionItem(
                id: "storage", icon: SettingIcon("externaldrive.fill", .gray),
                title: "VM drive not connected", detail: storageProblem + ".", pane: .virtualMachine
            ))
        }
        if networkMode == .bridged, !bridgeAvailable {
            items.append(AttentionItem(
                id: "network", icon: SettingIcon("network", .blue),
                title: "Network adapter unavailable", detail: "Omarchy will start offline.", pane: .network
            ))
        }
        if let usbDevice, usbEnabled, !usbConnected {
            items.append(AttentionItem(
                id: "usb", icon: SettingIcon("cable.connector", .gray),
                title: "\(usbDevice) is not connected", detail: "Omarchy will start without it.", pane: .sharing
            ))
        }
        return items
    }
}

struct LauncherView: View {
    @Environment(LauncherModel.self) private var model
    @State private var selection: LauncherPane? = LauncherPane.allCases.first {
        $0.rawValue == CommandLine.arguments.drop { $0 != "--pane" }.dropFirst().first
    } ?? .home

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar(selection: $selection)
        } detail: {
            pane
                .disabled(model.permissionPromptOpen)
                .navigationTitle(selection == .home ? (model.isRunning ? "Try Omarchy Settings" : "Try Omarchy") : (selection ?? .home).rawValue)
                .toolbar {
                    if selection != .home {
                        ToolbarItem(placement: .primaryAction) { LaunchToolbarButton() }
                    }
                }
        }
        .frame(minWidth: 760, minHeight: 500)
        .sheet(item: $model.activeSheet) { sheet in
            switch sheet {
            case .resources: ResourcesSheet()
            case .network: NetworkSheet()
            case .ports: PortForwardingSheet()
            case .usb: USBDeviceSheet()
            case .storage: StorageSheet()
            }
        }
        .alert(item: $model.activeAlert) { alert in
            switch alert {
            case .restart:
                Alert(
                    title: Text("Restart Try Omarchy?"),
                    message: Text("Save your work first. Omarchy will shut down and start again with your saved settings."),
                    primaryButton: .default(Text("Restart")) { model.shutDown(thenRestart: true) },
                    secondaryButton: .cancel()
                )
            case .shutDown:
                Alert(
                    title: Text("Shut down Omarchy to manage this VM?"),
                    message: Text("Save your work first. The settings window will stay open so you can change the VM location or reset it."),
                    primaryButton: .default(Text("Shut Down")) { model.shutDown(thenRestart: false) },
                    secondaryButton: .cancel()
                )
            case .skipLauncher:
                Alert(
                    title: Text("Skip the launcher"),
                    message: Text("Omarchy will start automatically with your current settings whenever you open Try Omarchy.\n\nTo see the launcher again, hold Option while opening the app, or inside Omarchy, open the Omarchy menu and choose Setup → Try Omarchy Settings."),
                    primaryButton: .default(Text("OK")) { model.skipLauncher = true },
                    secondaryButton: .cancel()
                )
            case .resetFinished:
                Alert(
                    title: Text("Try Omarchy has been reset"),
                    message: Text("The VM has been deleted. Up to 18.4 GB of disk space was reclaimed. A fresh VM will be prepared on the next launch.")
                )
            }
        }
    }

    @ViewBuilder private var pane: some View {
        switch selection ?? .home {
        case .home: HomePane(selection: $selection)
        case .permissions: Form { PermissionsSection() }.formStyle(.grouped)
        case .sharing: Form { SharingSection() }.formStyle(.grouped)
        case .network: Form { NetworkSection() }.formStyle(.grouped)
        case .virtualMachine: Form { VirtualMachineSection(); ResetSection() }.formStyle(.grouped)
        case .startup: Form { StartupSection() }.formStyle(.grouped)
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Environment(LauncherModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Binding var selection: LauncherPane?

    var body: some View {
        List(selection: $selection) {
            ForEach(LauncherPane.allCases) { pane in
                Label {
                    Text(pane.rawValue)
                } icon: {
                    pane.icon.environment(\.settingIconSize, 20)
                }
                .badge(pane == .home ? 0 : model.attentionItems.filter { $0.pane == pane }.count)
                .tag(pane)
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.appVersion)
                Button("Check for Updates…") { openWindow(id: "updates") }
                    .buttonStyle(.link)
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
    @Environment(LauncherModel.self) private var model
    @Binding var selection: LauncherPane?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                HStack(alignment: .center, spacing: 22) {
                    OmarchyAppTile(size: 104)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Try Omarchy")
                            .font(.system(size: 26, weight: .bold))
                        status
                        Text(model.guestReported ? model.guestLines[0] : "A fresh VM is prepared on first launch")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) { actions }
                            .padding(.top, 10)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 14)
                .padding(.horizontal, 8)
            }

            if !model.attentionItems.isEmpty {
                Section("Needs Attention") {
                    ForEach(model.attentionItems) { item in
                        SettingRow(icon: item.icon, title: item.title, detail: [item.detail]) {
                            Button("Review…") { selection = item.pane }
                        }
                    }
                }
            }

            Section("Quick Settings") {
                SettingRow(
                    icon: SettingIcon("arrow.up.left.and.arrow.down.right", .black),
                    title: "Immersive Mode",
                    detail: [model.immersive ? "Full Screen, Mac menu bar and Dock hidden" : "In a window, Mac menu bar and Dock available"]
                ) {
                    Toggle("Immersive Mode", isOn: $model.immersive)
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                }
                SettingRow(
                    icon: SettingIcon("folder.fill", .cyan),
                    title: "Shared Folder",
                    detail: [model.sharedFolderPath.map { model.sharedFolderEnabled ? "\($0) → \(model.sharedFolderGuestPath!)" : "\($0) · Not shared" } ?? "None"]
                ) {
                    if model.sharedFolderPath == nil {
                        Button("Choose…") { selection = .sharing }
                    } else {
                        Toggle("Shared Folder", isOn: $model.sharedFolderEnabled)
                            .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                }
                SettingRow(icon: SettingIcon("cpu", .purple), title: "Resources", detail: [model.resourceSummary]) {
                    Button("Configure…") { model.activeSheet = .resources }
                }
            }
            .disabled(model.settingsLocked)
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var status: some View {
        switch model.runState {
        case .ready:
            Text(model.attentionItems.isEmpty ? "Ready to launch" : "Ready to launch · review \(model.attentionItems.count == 1 ? "1 item" : "\(model.attentionItems.count) items") below")
                .foregroundStyle(.secondary)
        case .launching(let phase):
            Text(phase.rawValue).foregroundStyle(.secondary)
        case .resetting(let phase):
            Text(phase.rawValue).foregroundStyle(.secondary)
        case .running:
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("Running · some changes apply after a restart")
            }
            .foregroundStyle(.secondary)
        case .shuttingDown:
            Text("Waiting for Omarchy to shut down. Finish saving your work inside Omarchy.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var actions: some View {
        if model.isRunning {
            Button("Done") {}
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            Button("Restart…") { model.activeAlert = .restart }
                .controlSize(.large)
                .disabled(model.controlsBusy)
            Button("Shut Down…") { model.activeAlert = .shutDown }
                .controlSize(.large)
                .disabled(model.controlsBusy)
            if model.runState == .shuttingDown { ProgressView().controlSize(.small) }
        } else {
            Button {
                model.launch()
            } label: {
                Label(model.isLaunching ? "Launching…" : "Launch Omarchy", systemImage: "play.fill")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .keyboardShortcut(model.isLaunching ? nil : .defaultAction)
            .disabled(model.isLaunching || model.isResetting || model.storageMoveProgress != nil)
            if model.isLaunching || model.isResetting { ProgressView().controlSize(.small) }
        }
    }
}

/// Launch stays one click away from every settings pane.
private struct LaunchToolbarButton: View {
    @Environment(LauncherModel.self) private var model

    var body: some View {
        if model.isRunning {
            Button("Done") {}
        } else {
            Button {
                model.launch()
            } label: {
                Label(model.isLaunching ? "Launching…" : "Launch Omarchy", systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(model.isLaunching || model.isResetting)
            .keyboardShortcut(model.isLaunching ? nil : .defaultAction)
        }
    }
}

// MARK: - Permissions

private struct PermissionsSection: View {
    @Environment(LauncherModel.self) private var model

    var body: some View {
        Section {
            SettingRow(
                icon: SettingIcon("accessibility", .blue),
                title: "Accessibility",
                detail: ["Needed for the native keyboard experience with Super shortcuts."]
            ) {
                if model.accessibility == .authorized {
                    StatusLabel(text: "Allowed", symbol: "checkmark.circle.fill", color: .green)
                } else {
                    Button("Open Settings…") { model.request(\.accessibility) }
                }
            }
            SettingRow(
                icon: SettingIcon("mic.fill", .orange),
                title: "Microphone",
                detail: [microphoneDetail]
            ) {
                permissionControl(model.microphone, permission: \.microphone)
            }
            SettingRow(
                icon: SettingIcon("camera.fill", .green),
                title: "Camera",
                detail: [cameraDetail]
            ) {
                permissionControl(model.camera, permission: \.camera)
            }
        } footer: {
            SectionNote("Only Accessibility is needed for the full keyboard experience. Change these anytime in System Settings › Privacy & Security.")
        }
    }

    @ViewBuilder
    private func permissionControl(
        _ state: PermissionState,
        permission: ReferenceWritableKeyPath<LauncherModel, PermissionState>
    ) -> some View {
        switch state {
        case .authorized:
            StatusLabel(text: "Allowed", symbol: "checkmark.circle.fill", color: .green)
        case .notDetermined:
            Button("Allow…") { model.request(permission) }
        case .waiting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting…").foregroundStyle(.secondary)
            }
        case .denied:
            Button("Open Settings…") { model.request(permission) }
        case .restricted:
            StatusLabel(text: "Restricted", symbol: "lock.fill", color: .secondary)
        }
    }

    private var microphoneDetail: String {
        switch model.microphone {
        case .authorized: "Apps in Omarchy can record from your Mac microphone."
        case .notDetermined, .waiting: "Optional. Speaker playback works without microphone access."
        case .denied: "Recording is off. Speaker playback will still work."
        case .restricted: "Recording is unavailable because of this Mac’s policy."
        }
    }

    private var cameraDetail: String {
        switch model.camera {
        case .authorized: "Apps in Omarchy can use your Mac camera while they are recording."
        case .notDetermined, .waiting: "Optional. The camera turns on only while an Omarchy app uses it."
        case .denied: "The Mac camera is off inside Omarchy."
        case .restricted: "Camera access is unavailable because of this Mac’s policy."
        }
    }
}

// MARK: - Sharing

private struct SharingSection: View {
    @Environment(LauncherModel.self) private var model
    @State private var choosingFolder = false

    var body: some View {
        @Bindable var model = model
        Section {
            SettingRow(
                icon: SettingIcon("folder.fill", .cyan),
                title: "Shared Folder",
                detail: sharedFolderDetail
            ) {
                Button("Choose…") { choosingFolder = true }
                if model.sharedFolderPath != nil {
                    Toggle("Shared Folder", isOn: $model.sharedFolderEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
            }
            .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
                guard case .success(let url) = result else { return }
                model.sharedFolderPath = (url.path as NSString).abbreviatingWithTildeInPath
                model.sharedFolderEnabled = true
            }
            .disabled(model.settingsLocked)

            SettingRow(
                icon: SettingIcon("cable.connector", .gray),
                title: "USB Device",
                badge: "Experimental",
                detail: usbDetail,
                warning: usbWarning
            ) {
                Button("Choose…") { model.activeSheet = .usb }
                if model.usbDevice != nil {
                    Toggle("USB Device", isOn: $model.usbEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
            }
            .disabled(model.settingsLocked)
        }
    }

    private var sharedFolderDetail: [String] {
        guard let path = model.sharedFolderPath, let guest = model.sharedFolderGuestPath else {
            return ["Optional. Pick a Mac folder to use inside Omarchy under the same name."]
        }
        return model.sharedFolderEnabled
            ? ["\(path), available as \(guest) in Omarchy"]
            : ["\(path) · Not shared"]
    }

    private var usbWarning: String? {
        guard let device = model.usbDevice, model.usbEnabled, !model.usbConnected else { return nil }
        return "\(device) is not connected"
    }

    private var usbDetail: [String] {
        guard let device = model.usbDevice else {
            return ["Optional. Pass one connected Mac USB device to Omarchy. macOS keeps most devices for itself."]
        }
        if !model.usbEnabled { return ["\(device) · Not passed through"] }
        if !model.usbConnected { return ["Reconnect it at the selected port or choose it again. Omarchy will start without it."] }
        return ["\(device) appears in Omarchy; macOS keeps its data."]
    }
}

// MARK: - Network

private struct NetworkSection: View {
    @Environment(LauncherModel.self) private var model

    var body: some View {
        Section {
            SettingRow(
                icon: SettingIcon("network", .blue),
                title: "Network",
                detail: [networkDetail],
                warning: networkWarning
            ) {
                Button("Configure…") { model.activeSheet = .network }
            }
            .disabled(model.settingsLocked)

            SettingRow(
                icon: SettingIcon("arrow.left.arrow.right", .indigo),
                title: "Port Forwarding",
                detail: portDetail
            ) {
                if model.networkMode == .nat, !model.activePorts.isEmpty {
                    Text(model.activePorts.count == 1 ? "1 Port" : "\(model.activePorts.count) Ports")
                        .foregroundStyle(.secondary)
                }
                Button("Configure…") { model.activeSheet = .ports }
                    .disabled(model.networkMode == .bridged)
            }
            .disabled(model.settingsLocked)
        }
    }

    private var interfaceTitle: String {
        model.interfaces.first { $0.name == model.bridgeInterface }?.title ?? model.bridgeInterface
    }

    private var networkDetail: String {
        model.networkMode == .nat
            ? "Shared (NAT) · Uses your Mac’s connection"
            : "Bridged via \(interfaceTitle)"
    }

    private var networkWarning: String? {
        guard model.networkMode == .bridged else { return nil }
        if !model.bridgeAvailable { return "Adapter unavailable — Omarchy will start offline" }
        if !model.helperInstalled { return "Networking helper setup required" }
        return nil
    }

    private var portDetail: [String] {
        if model.networkMode == .bridged {
            return ["Inactive in bridged mode. Your saved rules are kept."]
        }
        let ports = model.activePorts
        switch ports.count {
        case 0:
            return ["Optional. Reach services running in Omarchy at localhost on this Mac."]
        case 1:
            let port = ports[0]
            return ["localhost:\(port.hostPort!) → Omarchy port \(port.guestPort!) · \(port.proto.rawValue)"]
        default:
            return ports.prefix(2).map { "localhost:\($0.hostPort!) → \($0.guestPort!) · \($0.proto.rawValue)" }
                + (ports.count > 2 ? ["and \(ports.count - 2) more"] : [])
        }
    }
}

// MARK: - Virtual machine

private struct VirtualMachineSection: View {
    @Environment(LauncherModel.self) private var model

    var body: some View {
        Section {
            SettingRow(
                icon: SettingIcon("cpu", .purple),
                title: "Resources",
                detail: [model.resourceSummary]
            ) {
                if model.resourcesAreDefault {
                    Text("Default").foregroundStyle(.secondary)
                }
                Button("Configure…") { model.activeSheet = .resources }
            }
            .disabled(model.settingsLocked)

            SettingRow(
                icon: SettingIcon(model.storageExternal ? "externaldrive.fill" : "internaldrive.fill", .gray),
                title: "Location",
                detail: locationDetail,
                warning: model.storageProblem
            ) {
                Button("Manage…") { model.activeSheet = .storage }
                    .disabled(model.prelaunchLocked || model.isResetting)
            }

            SettingRow(icon: .omarchy, title: "Omarchy", detail: model.guestLines) {
                if model.guestReported {
                    if model.guestCurrent {
                        StatusLabel(text: "Up to Date", symbol: "checkmark.circle.fill", color: .green)
                    } else {
                        StatusLabel(text: "Update Pending", symbol: "arrow.down.circle.fill", color: .orange)
                    }
                }
            }
        } footer: {
            SectionNote("Omarchy updates itself inside the VM with omarchy update.")
        }
    }

    private var locationDetail: [String] {
        if model.storageMoveProgress != nil { return ["Copying and verifying your VM… Original retained."] }
        var lines = [model.storagePath]
        if model.storageProblem == nil, !model.storageIsDefault {
            let volume = [model.storageVolume, model.storageExternal ? "External drive" : nil].compactMap { $0 }
            if !volume.isEmpty { lines.append(volume.joined(separator: " · ")) }
        }
        return lines
    }
}

// MARK: - Startup

private struct StartupSection: View {
    @Environment(LauncherModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            SettingRow(
                icon: SettingIcon("arrow.up.left.and.arrow.down.right", .black),
                title: "Immersive Mode",
                detail: [model.immersive
                    ? "Omarchy opens Full Screen with the Mac menu bar and Dock hidden."
                    : "Omarchy opens in a window with the Mac menu bar and Dock available."]
            ) {
                Toggle("Immersive Mode", isOn: $model.immersive)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            .disabled(model.settingsLocked)

            SettingRow(
                icon: SettingIcon("forward.fill", .orange),
                title: "Skip Launcher",
                detail: [model.isRunning
                    ? "Launch Omarchy with your saved settings. Open settings anytime from Omarchy’s Setup menu."
                    : "Launch Omarchy with your saved settings. Hold Option while opening the app to show the launcher."]
            ) {
                Toggle("Skip Launcher", isOn: Binding(
                    get: { model.skipLauncher },
                    set: { enabled in
                        if enabled { model.activeAlert = .skipLauncher } else { model.skipLauncher = false }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            .disabled(model.settingsLocked)
        }
    }
}

// MARK: - Reset

private struct ResetSection: View {
    @Environment(LauncherModel.self) private var model

    var body: some View {
        Section {
            SettingRow(
                icon: SettingIcon("arrow.counterclockwise", .red),
                title: "Reset Omarchy",
                detail: [model.isRunning
                    ? "Shut down Omarchy to change the VM location or reset it to factory settings."
                    : "Permanently erase this VM. The next launch creates a fresh one in the same folder."]
            ) {
                if case .resetting(let phase) = model.runState {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(phase.rawValue).foregroundStyle(.secondary)
                    }
                } else if model.isRunning {
                    Button("Shut Down…") { model.activeAlert = .shutDown }
                        .disabled(model.controlsBusy)
                } else {
                    Button("Reset…", role: .destructive) { ResetConfirmation.present(model: model) }
                        .foregroundStyle(.red)
                        .disabled(model.prelaunchLocked)
                }
            }
        }
    }
}

/// The real launcher already uses this NSAlert. It stays AppKit because the
/// destructive button must remain disabled until the phrase is typed.
@MainActor
enum ResetConfirmation {
    nonisolated static let phrase = "Try Omarchy"

    static func present(model: LauncherModel) {
        guard let window = NSApp.keyWindow else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Reset Omarchy to factory settings?"
        alert.informativeText = "This permanently erases everything in this Omarchy virtual machine, including apps, files, accounts, and settings. This cannot be undone or recovered. Resetting may free up to 18.4 GB of disk space."
        alert.addButton(withTitle: "Cancel")
        let reset = alert.addButton(withTitle: "Reset")
        reset.hasDestructiveAction = true
        reset.isEnabled = false

        let instruction = NSTextField(labelWithString: "Type \(phrase) to confirm")
        instruction.font = .systemFont(ofSize: 12, weight: .medium)
        let field = NSTextField(string: "")
        field.placeholderString = phrase
        let stack = NSStackView(views: [instruction, field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 48)
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        alert.accessoryView = stack

        let observer = NotificationCenter.default.addObserver(
            forName: NSControl.textDidChangeNotification, object: field, queue: .main
        ) { _ in
            reset.isEnabled = field.stringValue == phrase
        }
        alert.beginSheetModal(for: window) { response in
            NotificationCenter.default.removeObserver(observer)
            if response == .alertSecondButtonReturn, field.stringValue == phrase {
                model.reset()
            }
        }
        DispatchQueue.main.async { window.makeFirstResponder(field) }
    }
}
