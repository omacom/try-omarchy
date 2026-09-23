import AppKit

/// Picks the single Mac USB device Omarchy may take over on the next launch.
///
/// One device rather than "all devices": `usb-host` claims a device away from
/// macOS for as long as the VM runs, so a blanket grant would hand the guest
/// this Mac's keyboard, dock, and display controls the moment it starts.
@MainActor
final class USBDeviceEditor: NSObject {
    private let alert = NSAlert()
    private let devices = NSPopUpButton()
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let stack = NSStackView()
    private let save: (USBDevicePreference) -> Void
    private let didClose: () -> Void

    init(
        preference: USBDevicePreference,
        connected: [USBDeviceIdentity],
        save: @escaping (USBDevicePreference) -> Void,
        didClose: @escaping () -> Void
    ) {
        // A device saved earlier stays selectable while it is unplugged, so
        // reopening this panel cannot silently forget it.
        let unplugged = preference.device.flatMap { saved in
            connected.contains { $0.matchesSelection(saved) } ? nil : saved
        }
        let choices = connected + (unplugged.map { [$0] } ?? [])
        self.save = save
        self.didClose = didClose
        super.init()

        alert.messageText = "USB device"
        alert.informativeText = "Experimental. The chosen device applies the next time you start Omarchy."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.isEnabled = !choices.isEmpty

        for device in connected {
            addDevice(device, title: device.selectionName)
        }
        if let unplugged {
            addDevice(unplugged, title: "Not connected: \(unplugged.selectionName)")
        }
        if let saved = preference.device,
           let index = choices.firstIndex(where: { $0.matchesSelection(saved) }) {
            devices.selectItem(at: index)
        }
        devices.setAccessibilityLabel("USB device")
        devices.isEnabled = !choices.isEmpty

        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.stringValue = choices.isEmpty
            ? "No USB devices are connected to this Mac. Plug one in, then open this panel again."
            : """
                Omarchy can only take a device macOS does not already drive. Drives, keyboards, audio, video and iPhones appear in the VM \
                without their data; macOS keeps them.

                The choice stays with this USB port. After moving the device, choose it again.

                Unplugging or replugging the device while Omarchy runs can freeze the window for up to 30 seconds.
                """

        let rows: [NSView] = [devices, detail]
        for row in rows { stack.addArrangedSubview(row) }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setContentHuggingPriority(.required, for: .vertical)
        for row in rows { row.widthAnchor.constraint(equalToConstant: 430).isActive = true }
        stack.layoutSubtreeIfNeeded()
        stack.setFrameSize(NSSize(width: 430, height: stack.fittingSize.height))
        alert.accessoryView = stack
        alert.layout()
    }

    private func addDevice(_ device: USBDeviceIdentity, title: String) {
        // NSPopUpButton.addItem(withTitle:) removes an earlier duplicate title.
        // Explicit menu items keep every entry, and its identity travels with it.
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = device
        devices.menu?.addItem(item)
    }

    var selectedDevice: USBDeviceIdentity? {
        devices.selectedItem?.representedObject as? USBDeviceIdentity
    }

    func beginSheet(for window: NSWindow) {
        alert.beginSheetModal(for: window) { [self] response in
            if response == .alertFirstButtonReturn,
               let device = selectedDevice {
                // Choosing a device is the act of turning passthrough on; the
                // row's own button is what turns it back off.
                save(USBDevicePreference(
                    device: device,
                    isEnabled: true
                ))
            }
            didClose()
        }
    }
}
