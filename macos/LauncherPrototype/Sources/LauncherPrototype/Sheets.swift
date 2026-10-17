import AppKit
import SwiftUI

// MARK: - Resources

struct ResourcesSheet: View {
    @Environment(LauncherModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var cores = 4
    @State private var memoryGiB = 8
    @State private var diskGiB: Int?

    var body: some View {
        SheetScaffold(
            icon: SettingIcon("cpu", .purple),
            title: "Resources",
            subtitle: "Changes apply the next time you start Omarchy."
        ) {
            Section {
                Picker(selection: $cores) {
                    ForEach(1...model.maximumCores, id: \.self) { count in
                        Text(count == model.defaultCores ? "\(count) cores · default" : "\(count) cores").tag(count)
                    }
                } label: {
                    Text("Processor cores")
                    Text("Shared with macOS. More cores may help demanding workloads.")
                }
                Picker(selection: $memoryGiB) {
                    ForEach(model.memoryChoicesGiB, id: \.self) { choice in
                        Text(memoryTitle(choice)).tag(choice)
                    }
                } label: {
                    Text("Memory")
                    Text("Shared with macOS. At least 4 GiB stays available to macOS.")
                }
            }
            Section {
                LabeledContent {
                    HStack(spacing: 6) {
                        TextField("Disk size", value: $diskGiB, format: .number.grouping(.never), prompt: Text("\(model.minimumDiskGiB)"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 72)
                        Text("GiB").foregroundStyle(.secondary)
                    }
                } label: {
                    Text("Maximum disk size")
                    Text("Can only increase. Currently \(model.minimumDiskGiB) GiB.")
                }
            } footer: {
                SectionNote("Uses Mac storage as data is written, up to this capacity. Space is not reserved.")
            }
        } actions: {
            Button("Restore Defaults") {
                cores = model.defaultCores
                memoryGiB = model.defaultMemoryGiB
                diskGiB = nil
            }
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                model.cores = cores
                model.memoryGiB = memoryGiB
                model.diskGiB = diskGiB
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .onAppear {
            cores = model.cores
            memoryGiB = model.memoryGiB
            diskGiB = model.diskGiB
        }
    }

    private func memoryTitle(_ choice: Int) -> String {
        if choice == model.defaultMemoryGiB { return "\(choice) GiB · default" }
        return choice >= 16 ? "\(choice) GiB · may slow macOS" : "\(choice) GiB"
    }
}

// MARK: - Network

struct NetworkSheet: View {
    @Environment(LauncherModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var mode = NetworkMode.nat
    @State private var interface = "en0"
    @State private var bridgedSSH = false
    @State private var confirmingNewMAC = false
    @State private var confirmingHelperRemoval = false

    var body: some View {
        SheetScaffold(
            icon: SettingIcon("network", .blue),
            title: "Network",
            subtitle: "Changes apply the next time you start Omarchy.",
            width: 520
        ) {
            Section {
                Picker("Mode", selection: $mode) {
                    ForEach(NetworkMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                SectionNote(mode == .nat
                    ? "Omarchy uses your Mac’s network connection. No additional setup is needed. Saved port-forwarding rules apply in this mode."
                    : "Services listening on the guest network interface can be reached from the LAN. Saved port-forwarding rules are inactive.")
            }

            if mode == .bridged {
                Section {
                    Picker("Adapter", selection: $interface) {
                        ForEach(model.interfaces) { item in
                            Text(item.title).tag(item.name)
                        }
                        if !model.bridgeAvailable, !model.interfaces.contains(where: { $0.name == model.bridgeInterface }) {
                            Text("Unavailable: \(model.bridgeInterface)").tag(model.bridgeInterface)
                        }
                    }
                    Toggle("Allow SSH connections from the LAN", isOn: $bridgedSSH)
                    LabeledContent {
                        HStack(spacing: 6) {
                            Text(model.macAddress)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(model.macAddress, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy MAC Address")
                        }
                    } label: {
                        Text("MAC address")
                        Text("Stays the same when you update or move this VM.")
                    }
                    LabeledContent("Copied this VM?") {
                        Button("Generate New MAC…") { confirmingNewMAC = true }
                            .disabled(model.isRunning)
                    }
                }

                Section {
                    LabeledContent {
                        if model.helperInstalled {
                            StatusLabel(text: "Enabled", symbol: "checkmark.circle.fill", color: .green)
                        } else {
                            StatusLabel(text: "Not Set Up", symbol: "exclamationmark.triangle.fill", color: .orange)
                        }
                    } label: {
                        Text("Networking helper")
                        Text("Approved once in System Settings. Later bridged launches don’t ask for your password.")
                    }
                    HStack {
                        Button(model.helperInstalled ? "Repair…" : "Set Up…") { model.helperInstalled = true }
                        Spacer()
                        Button("Remove Helper…") { confirmingHelperRemoval = true }
                            .disabled(!model.helperInstalled)
                    }
                }
            }
        } actions: {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                model.networkMode = mode
                model.bridgeInterface = interface
                model.bridgeAvailable = model.interfaces.contains { $0.name == interface }
                model.bridgedSSH = bridgedSSH
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .onAppear {
            mode = model.networkMode
            interface = model.bridgeInterface
            bridgedSSH = model.bridgedSSH
        }
        .alert("Generate a new MAC address?", isPresented: $confirmingNewMAC) {
            Button("Change MAC Address") { model.macAddress = "52:54:00:9e:41:0c" }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Current: \(model.macAddress)\nNew: 52:54:00:9e:41:0c\n\nDHCP reservations may need updating. This change is saved immediately.")
        }
        .alert("Remove the networking helper?", isPresented: $confirmingHelperRemoval) {
            Button("Remove Helper", role: .destructive) { model.helperInstalled = false }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This stops networking for any active bridged Omarchy VM. Shut those VMs down first. You can set up the helper again later.")
        }
    }
}

// MARK: - Port forwarding

struct PortForwardingSheet: View {
    @Environment(LauncherModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var mappings: [PortMapping] = []

    var body: some View {
        SheetScaffold(
            icon: SettingIcon("arrow.left.arrow.right", .indigo),
            title: "Port Forwarding",
            subtitle: "Reach services in Omarchy at localhost on this Mac. From Omarchy, reach the Mac at 10.0.2.2.",
            width: 540
        ) {
            Section {
                if mappings.isEmpty {
                    ContentUnavailableView {
                        Label("No Ports Forwarded", systemImage: "arrow.left.arrow.right")
                    } description: {
                        Text("Add a port for a service listening in Omarchy.")
                    }
                    .padding(.vertical, 8)
                } else {
                    ForEach($mappings) { $mapping in
                        PortMappingRow(mapping: $mapping) {
                            mappings.removeAll { $0.id == mapping.id }
                        }
                    }
                }
            } header: {
                if !mappings.isEmpty {
                    HStack {
                        Text("On this Mac")
                        Spacer()
                        Text("In Omarchy").padding(.trailing, 116)
                    }
                }
            } footer: {
                HStack(spacing: 8) {
                    Button {
                        mappings.append(PortMapping())
                    } label: {
                        Label("Add Port", systemImage: "plus")
                    }
                    Button {
                        mappings.append(PortMapping(proto: .tcp, hostPort: 2222, guestPort: 22))
                    } label: {
                        Label("Add SSH", systemImage: "terminal")
                    }
                    .disabled(mappings.contains { $0.guestPort == 22 })
                    Spacer()
                }
                .padding(.top, 4)
            }
        } actions: {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                model.ports = mappings
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .frame(height: 400)
        .onAppear { mappings = model.ports }
    }
}

private struct PortMappingRow: View {
    @Binding var mapping: PortMapping
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("localhost :").foregroundStyle(.secondary)
            TextField("Mac port", value: $mapping.hostPort, format: .number.grouping(.never), prompt: Text("8080"))
                .labelsHidden()
                .frame(width: 64)
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
            Spacer()
            Text("port").foregroundStyle(.secondary)
            TextField("Omarchy port", value: $mapping.guestPort, format: .number.grouping(.never), prompt: Text("3000"))
                .labelsHidden()
                .frame(width: 64)
            Picker("Protocol", selection: $mapping.proto) {
                ForEach(PortProtocol.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Button(action: remove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove This Port")
        }
    }
}

// MARK: - USB device

struct USBDeviceSheet: View {
    @Environment(LauncherModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var device: String?

    var body: some View {
        SheetScaffold(
            icon: SettingIcon("cable.connector", .gray),
            title: "USB Device",
            subtitle: "Experimental. The chosen device applies the next time you start Omarchy."
        ) {
            Section {
                Picker("Device", selection: $device) {
                    Text("None").tag(String?.none)
                    Divider()
                    ForEach(model.connectedUSBDevices, id: \.self) { name in
                        Text(name).tag(Optional(name))
                    }
                    if let saved = model.usbDevice, !model.connectedUSBDevices.contains(saved) {
                        Text("Not connected: \(saved)").tag(Optional(saved))
                    }
                }
            } footer: {
                SectionNote("The device appears in Omarchy, but macOS keeps most devices for itself, including keyboards, storage, and audio. Keep it connected to the same port.")
            }
        } actions: {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                model.usbDevice = device
                model.usbEnabled = device != nil
                model.usbConnected = device.map(model.connectedUSBDevices.contains) ?? true
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .onAppear { device = model.usbDevice }
    }
}

// MARK: - Storage

struct StorageSheet: View {
    @Environment(LauncherModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false

    var body: some View {
        SheetScaffold(
            icon: SettingIcon(model.storageExternal ? "externaldrive.fill" : "internaldrive.fill", .gray),
            title: "Manage VMs",
            subtitle: "Your VM starts only when you return to the launcher and press Launch.",
            width: 540
        ) {
            Section("Selected VM") {
                LabeledContent {
                    Button("Show in Finder") {}
                } label: {
                    Text(model.storagePath)
                        .truncationMode(.middle)
                        .lineLimit(1)
                    Text(selectionStatus)
                }
                if let progress = model.storageMoveProgress {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: progress)
                        Text("Copying and verifying… \(Int(progress * 100))%")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                action(
                    "Switch to another VM",
                    "Choose a saved VM in another folder. Files stay where they are.",
                    button: "Choose VM…"
                ) {}
                action(
                    "Move the selected VM",
                    "Copy this VM to a new folder, verify it, and switch to the copy. The original remains a recovery copy.",
                    button: "Choose Destination…"
                ) { model.moveStorage() }
                action(
                    "Create a separate VM",
                    "Choose an empty folder. A new VM is created on the next launch; the selected VM is kept.",
                    button: "Choose Folder…"
                ) {}
                if !model.storageIsDefault {
                    action(
                        "Use the default folder",
                        "~/Library/Application Support/Try Omarchy",
                        button: "Use Default"
                    ) {
                        model.storagePath = "~/Library/Application Support/Try Omarchy"
                        model.storageIsDefault = true
                        model.storageExternal = false
                        model.storageVolume = nil
                        model.storageProblem = nil
                    }
                }
            }
            Section {
                LabeledContent {
                    Button("Move to Trash…", role: .destructive) { confirmingDelete = true }
                        .foregroundStyle(.red)
                } label: {
                    Text("Delete the selected VM")
                    Text("Other VM copies are kept. You can recover it until the Trash is emptied.")
                }
            }
        } actions: {
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .disabled(model.storageMoveProgress != nil)
        .frame(height: 560)
        .alert("Delete the selected VM?", isPresented: $confirmingDelete) {
            Button("Move to Trash", role: .destructive) {}
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The folder at \(model.storagePath) moves to the Trash.")
        }
    }

    private var selectionStatus: String {
        if model.storageProblem != nil { return "This folder is unavailable. Reconnect its drive or choose another VM." }
        return "Your next launch will boot the VM in this folder."
    }

    private func action(_ title: String, _ detail: String, button: String, perform: @escaping () -> Void) -> some View {
        LabeledContent {
            Button(button, action: perform)
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

// MARK: - Updates window

struct UpdatesView: View {
    @Environment(LauncherModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                HStack(spacing: 14) {
                    OmarchyAppTile(size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Try Omarchy").font(.headline)
                        Text(model.appVersion).foregroundStyle(.secondary)
                    }
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        if model.checkingForUpdates { ProgressView().controlSize(.small) }
                        Button("Check Now") { model.checkForUpdates() }
                            .disabled(model.checkingForUpdates)
                    }
                } label: {
                    Text(model.updateStatus)
                }
                LabeledContent("Release notes") {
                    Button("Open on GitHub…") {}
                }
            }
            Section {
                Toggle(isOn: $model.automaticUpdateChecks) {
                    Text("Automatically check for updates")
                    Text("Contacts GitHub at most once a day when you open the app. Updates aren’t downloaded or installed automatically.")
                }
            } footer: {
                SectionNote("Shut down Omarchy before replacing the Mac app. Your VM and settings are kept; Omarchy itself updates separately inside the VM.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
