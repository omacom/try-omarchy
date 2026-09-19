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
    /// The popup's entries, in the order they were added.
    private let choices: [USBDeviceIdentity]
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
        let saved = preference.device
        let savedIsConnected = saved.map { device in
            connected.contains { $0.vendorId == device.vendorId && $0.productId == device.productId }
        } ?? true
        choices = savedIsConnected ? connected : connected + [saved!]
        self.save = save
        self.didClose = didClose
        super.init()

        alert.messageText = "USB device"
        alert.informativeText = "Experimental. The chosen device applies the next time you start Omarchy."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        for device in connected {
            devices.addItem(withTitle: device.displayName)
        }
        if !savedIsConnected, let saved {
            devices.addItem(withTitle: "Not connected: \(saved.displayName)")
        }
        if let saved,
           let index = choices.firstIndex(where: {
               $0.vendorId == saved.vendorId && $0.productId == saved.productId
           }) {
            devices.selectItem(at: index)
        }
        devices.setAccessibilityLabel("USB device")
        devices.isEnabled = !choices.isEmpty
        devices.target = self
        devices.action = #selector(update)

        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor

        let rows: [NSView] = [devices, detail]
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
        detail.stringValue = choices.isEmpty
            ? "No USB devices are connected to this Mac. Plug one in, then open this panel again."
            : """
                Omarchy can only take a device macOS does not already drive. Drives, keyboards, audio, video and iPhones appear in the VM \
                without their data, because macOS keeps them until this app is signed with Apple's com.apple.vm.device-access entitlement.

                Unplugging or replugging the device while Omarchy runs can freeze the window for up to 30 seconds.
                """
        alert.buttons.first?.isEnabled = !choices.isEmpty
        stack.layoutSubtreeIfNeeded()
        stack.setFrameSize(NSSize(width: 430, height: stack.fittingSize.height))
        alert.layout()
    }

    func beginSheet(for window: NSWindow) {
        alert.beginSheetModal(for: window) { [self] response in
            if response == .alertFirstButtonReturn,
               choices.indices.contains(devices.indexOfSelectedItem) {
                // Choosing a device is the act of turning passthrough on; the
                // row's own button is what turns it back off.
                save(USBDevicePreference(
                    device: choices[devices.indexOfSelectedItem],
                    isEnabled: true
                ))
            }
            didClose()
        }
    }
}
