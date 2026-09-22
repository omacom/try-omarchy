import AppKit

@MainActor
final class NetworkEditor: NSObject {
    private let alert = NSAlert()
    private let mode = NSPopUpButton()
    private let interface = NSPopUpButton()
    private let explanation = NSTextField(wrappingLabelWithString: "")
    private let ssh = NSButton(checkboxWithTitle: "Allow SSH connections from the LAN", target: nil, action: nil)
    private let macAddress = NSTextField(wrappingLabelWithString: "")
    private let macHelp = NSTextField(wrappingLabelWithString: "This address stays the same when you update or move this VM. For a copied VM, generate a new address before running both copies.")
    private let copyMAC = NSButton(title: "Copy MAC", target: nil, action: nil)
    private let regenerateMAC = NSButton(title: "Generate new MAC…", target: nil, action: nil)
    private let macControls = NSStackView()
    private let identity: VMNetworkIdentityAccess
    private var currentMAC = ""
    private var canReplaceMAC = false
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let serviceStatus = NSTextField(wrappingLabelWithString: "")
    private let setup = NSButton()
    private let remove = NSButton()
    private let controls = NSStackView()
    private let stack = NSStackView()
    private var serviceBusy = false
    private var serviceResult: String?
    private let savedPreferences: VMNetworkPreferences
    private let interfaces: [VMBridgeInterface]
    private let save: (VMNetworkPreferences) -> String?
    private let didClose: () -> Void

    init(preferences: VMNetworkPreferences, interfaces: [VMBridgeInterface],
         identity: VMNetworkIdentityAccess = .unavailable,
         save: @escaping (VMNetworkPreferences) -> String?, didClose: @escaping () -> Void) {
        self.identity = identity
        self.savedPreferences = preferences
        self.interfaces = interfaces
        self.save = save
        self.didClose = didClose
        super.init()
        alert.messageText = "Networking"
        alert.informativeText = "Changes apply the next time you start Omarchy."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        mode.addItems(withTitles: ["Shared connection (NAT)", "Bridged, own LAN address"])
        mode.selectItem(at: preferences.mode == .nat ? 0 : 1)
        mode.target = self; mode.action = #selector(update)
        mode.setAccessibilityLabel("Network mode")
        for item in interfaces { interface.addItem(withTitle: item.title) }
        if let index = interfaces.firstIndex(where: { $0.name == preferences.interface }) {
            interface.selectItem(at: index)
        } else if !preferences.interface.isEmpty {
            interface.addItem(withTitle: "Unavailable: \(preferences.interface)")
            interface.selectItem(at: interfaces.count)
        }
        interface.target = self; interface.action = #selector(update)
        interface.setAccessibilityLabel("Bridge interface")
        ssh.state = preferences.bridgedSSH ? .on : .off
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        setup.title = "Set Up / Repair Networking…"
        setup.target = self; setup.action = #selector(setUpService)
        remove.title = "Remove Networking Helper"
        remove.target = self; remove.action = #selector(removeService)
        controls.addArrangedSubview(setup)
        controls.addArrangedSubview(remove)
        controls.spacing = 8
        macAddress.setAccessibilityLabel("Bridged MAC address")
        macAddress.isSelectable = true
        macHelp.font = .systemFont(ofSize: 12)
        macHelp.textColor = .secondaryLabelColor
        if identity.isEphemeral {
            macHelp.stringValue = "Ephemeral VMs receive a new MAC address on each launch."
        }
        copyMAC.target = self; copyMAC.action = #selector(copyAddress)
        regenerateMAC.target = self; regenerateMAC.action = #selector(regenerateAddress)
        macControls.addArrangedSubview(copyMAC)
        macControls.addArrangedSubview(regenerateMAC)
        macControls.spacing = 8
        loadIdentity()
        let rows: [NSView] = [mode, interface, explanation, ssh, macAddress, macHelp, macControls, detail, serviceStatus, controls]
        for row in rows { stack.addArrangedSubview(row) }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setContentHuggingPriority(.required, for: .vertical)
        for row in rows { row.widthAnchor.constraint(equalToConstant: 430).isActive = true }
        alert.accessoryView = stack
        update()
    }

    @objc private func update() {
        serviceStatus.stringValue = serviceBusy ? "Checking networking helper…" : (serviceResult ?? NetworkService.statusText)
        setup.isEnabled = !serviceBusy
        remove.isEnabled = !serviceBusy
        mode.isEnabled = !serviceBusy
        alert.buttons.last?.isEnabled = !serviceBusy
        let bridged = mode.indexOfSelectedItem == 1
        for view in [interface, explanation, ssh, macAddress, macHelp, macControls, serviceStatus, controls] as [NSView] {
            view.isHidden = !bridged
        }
        let valid = interfaces.indices.contains(interface.indexOfSelectedItem)
        interface.isEnabled = bridged && !serviceBusy
        let compatibilityRequired = bridged && valid && VMNetworkPolicy.requiresWiFiCompatibility(
            isWiFi: interfaces[interface.indexOfSelectedItem].isWiFi,
            supported: VMNetworkPolicy.supportsWiFiCompatibility)
        explanation.stringValue = compatibilityRequired
            ? "Wi-Fi bridging on this Mac temporarily adjusts DHCP handling for all bridged VMs, including other virtualization apps. The previous setting is restored when Omarchy stops. Saving this choice enables that handling automatically."
            : "The networking helper is approved once through macOS. Subsequent bridged launches do not ask for your password."
        copyMAC.isEnabled = !serviceBusy && !currentMAC.isEmpty
        regenerateMAC.isEnabled = !serviceBusy && !currentMAC.isEmpty && canReplaceMAC
        ssh.isEnabled = bridged && !serviceBusy
        alert.buttons.first?.isEnabled = !serviceBusy && (!bridged || valid || !savedPreferences.interface.isEmpty)
        detail.stringValue = bridged
            ? "Bridging requires one-time helper approval in System Settings. Services listening on the guest network interface can be reached from the LAN. Saved port-forwarding rules are inactive."
            : "Omarchy uses your Mac’s network connection. No additional setup is needed. Saved port-forwarding rules apply in this mode."
        if bridged && !valid { detail.stringValue = "The selected adapter is unavailable. Omarchy will start offline and connect automatically when this adapter returns." }
        stack.layoutSubtreeIfNeeded()
        stack.setFrameSize(NSSize(width: 430, height: stack.fittingSize.height))
        alert.layout()
    }

    private func loadIdentity() {
        do {
            currentMAC = try identity.read()
            canReplaceMAC = !currentMAC.isEmpty && identity.canReplace()
            regenerateMAC.toolTip = identity.isEphemeral
                ? "Ephemeral MAC addresses cannot be changed here."
                : (canReplaceMAC ? nil : "Shut down the VM before changing its MAC address.")
            macAddress.stringValue = currentMAC.isEmpty
                ? (identity.isEphemeral ? "MAC address: assigned on each bridged launch."
                    : "MAC address: assigned on the first bridged launch.")
                : "MAC address: \(currentMAC)"
        } catch {
            currentMAC = ""
            macAddress.stringValue = error.localizedDescription
        }
    }

    @objc private func copyAddress() {
        guard !currentMAC.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentMAC, forType: .string)
    }

    @objc private func regenerateAddress() {
        guard !serviceBusy, !currentMAC.isEmpty else { return }
        var proposed = VMNetworkIdentityAccess.proposedMAC()
        while proposed == currentMAC { proposed = VMNetworkIdentityAccess.proposedMAC() }
        let confirmation = NSAlert()
        confirmation.messageText = "Generate a new MAC address?"
        confirmation.informativeText = "Current: \(currentMAC)\nNew: \(proposed)\n\nThis VM must be shut down. DHCP reservations may need updating. This change is saved immediately, independently of the Networking Save button."
        confirmation.addButton(withTitle: "Change MAC Address")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        do {
            _ = try identity.replace(currentMAC, proposed)
        } catch {
            let problem = NSAlert()
            problem.messageText = "MAC address could not be changed"
            problem.informativeText = error.localizedDescription
            problem.runModal()
        }
        loadIdentity()
        update()
    }

    private func serviceAction(success: String? = nil, _ action: @escaping @MainActor () async throws -> Void) {
        guard !serviceBusy else { return }
        serviceBusy = true
        serviceResult = nil
        update()
        Task { @MainActor in
            do {
                try await action()
                serviceResult = success
            } catch {
                serviceResult = "Networking helper check failed. Use Set Up / Repair to check again."

                let problem = NSAlert()
                problem.messageText = "Networking helper"
                problem.informativeText = error.localizedDescription
                problem.runModal()
            }
            serviceBusy = false
            update()
        }
    }

    @objc private func setUpService() { serviceAction(success: "Networking helper ready — connection verified") { try await NetworkService.repair() } }
    @objc private func removeService() {
        guard !serviceBusy else { return }
        let confirmation = NSAlert()
        confirmation.messageText = "Remove the networking helper?"
        confirmation.informativeText = "This stops networking for any active bridged Omarchy VM. Shut those VMs down first. You can set up the helper again later."
        confirmation.addButton(withTitle: "Remove Helper")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        serviceAction { try await NetworkService.remove() }
    }

    func beginSheet(for window: NSWindow) {
        alert.beginSheetModal(for: window) { [self] response in
            if response == .alertFirstButtonReturn {
                let bridged = mode.indexOfSelectedItem == 1
                let selected = interfaces.indices.contains(interface.indexOfSelectedItem)
                    ? interfaces[interface.indexOfSelectedItem] : nil
                let value = VMNetworkPreferences(mode: bridged ? .bridged : .nat,
                    interface: selected?.name ?? savedPreferences.interface,
                    wifiCompatibility: selected.map { VMNetworkPolicy.requiresWiFiCompatibility(isWiFi: $0.isWiFi, supported: VMNetworkPolicy.supportsWiFiCompatibility) } ?? savedPreferences.wifiCompatibility,
                    bridgedSSH: ssh.state == .on)
                if let error = save(value) {
                    let problem = NSAlert()
                    problem.messageText = "Networking could not be saved"
                    problem.informativeText = error
                    problem.beginSheetModal(for: window)
                }
            }
            didClose()
        }
    }
}
