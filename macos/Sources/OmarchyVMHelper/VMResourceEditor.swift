import AppKit

/// Edits a draft; only Save publishes it to the next VM launch.
@MainActor
final class VMResourceEditor: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private let minimumDiskGiB: Int
    private let diskField = NSTextField()
    private let limits: VMResourceLimits
    private let saveHandler: (VMResources) -> Void
    private let closeHandler: () -> Void
    private(set) var window: NSWindow!
    private let cpuPopup = NSPopUpButton()
    private let memoryPopup = NSPopUpButton()
    private let validationLabel = NSTextField(wrappingLabelWithString: "")
    private var saveButton: NSButton!
    private var didClose = false

    init(
        resources: VMResources,
        limits: VMResourceLimits,
        minimumDiskGiB: Int = 1,
        save: @escaping (VMResources) -> Void,
        didClose: @escaping () -> Void
    ) {
        self.minimumDiskGiB = minimumDiskGiB
        self.limits = limits
        saveHandler = save
        closeHandler = didClose
        super.init()
        buildWindow()
        setFields(limits.resolve(resources))
    }

    func beginSheet(for parent: NSWindow) {
        parent.beginSheet(window)
        window.makeFirstResponder(cpuPopup)
    }

    func dismiss() {
        guard !didClose else { return }
        didClose = true
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
        closeHandler()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }

    private func buildWindow() {
        let width: CGFloat = 540
        window = NativeSheetChrome.window(title: "Virtual machine resources", width: width)
        window.delegate = self

        let heading = NativeSheetChrome.header(
            symbol: "cpu", color: .systemPurple, title: "Resources",
            subtitle: "This Mac has \(limits.hostCPUCount) processor cores and \(limits.hostMemoryBytes / VMResourceLimits.bytesPerGiB) GiB of memory. Changes apply on the next launch."
        )

        for choice in limits.cpuRange {
            let suffix = choice == limits.defaults.cpuCount
                ? " · default"
                : choice == limits.cpuRange.upperBound ? " · all cores" : ""
            cpuPopup.addItem(withTitle: "\(choice) cores\(suffix)")
            cpuPopup.lastItem?.tag = choice
        }
        cpuPopup.target = self
        cpuPopup.action = #selector(changeResources)
        cpuPopup.isEnabled = limits.cpuRange.count > 1
        cpuPopup.identifier = NSUserInterfaceItemIdentifier("vm-resources-cpu")
        cpuPopup.setAccessibilityLabel("Processor cores")
        cpuPopup.setAccessibilityHelp("Choose from \(limits.cpuRange.lowerBound) to \(limits.cpuRange.upperBound) cores, shared with macOS")

        for choice in limits.memoryChoicesGiB {
            memoryPopup.addItem(withTitle: MemoryPolicy.choiceTitle(
                memoryMiB: choice * 1024, hostMemoryMiB: limits.hostMemoryMiB
            ))
            memoryPopup.lastItem?.tag = choice
        }
        memoryPopup.target = self
        memoryPopup.action = #selector(changeResources)
        memoryPopup.isEnabled = limits.memoryChoicesGiB.count > 1
        memoryPopup.identifier = NSUserInterfaceItemIdentifier("vm-resources-memory")
        memoryPopup.setAccessibilityLabel("Memory")
        memoryPopup.setAccessibilityHelp("Higher allocations may affect macOS performance; at least 4 GiB stays available to macOS")

        diskField.placeholderString = "Current: \(minimumDiskGiB) GiB"
        diskField.alignment = .right
        diskField.delegate = self
        diskField.identifier = NSUserInterfaceItemIdentifier("vm-resources-disk")
        diskField.setAccessibilityLabel("Maximum disk size in GiB")
        diskField.setAccessibilityHelp("Increases apply on the next launch; existing disks cannot shrink.")

        let group = NativeSheetChrome.group([
            NativeSheetChrome.row(
                title: "Processor cores",
                detail: "Shared with macOS. More cores may help demanding workloads.",
                control: cpuPopup
            ),
            NativeSheetChrome.row(title: "Memory", detail: "Shared with macOS", control: memoryPopup),
            NativeSheetChrome.row(title: "Maximum disk size (GiB)", detail: "Can only increase.", control: diskField),
        ])
        NSLayoutConstraint.activate([
            cpuPopup.widthAnchor.constraint(equalTo: memoryPopup.widthAnchor),
            cpuPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            diskField.widthAnchor.constraint(equalToConstant: 80),
        ])
        let diskNote = NativeSheetChrome.footnote(
            "Uses Mac storage as data is written, up to this capacity. Space is not reserved."
        )

        NativeSheetChrome.styleFootnote(validationLabel)
        validationLabel.identifier = NSUserInterfaceItemIdentifier("vm-resources-validation")
        validationLabel.setAccessibilityElement(true)
        let validation = NativeSheetChrome.inset(validationLabel)
        validation.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true

        let defaults = button("Use Defaults", action: #selector(useDefaults), identifier: "defaults")
        let cancel = button("Cancel", action: #selector(cancel), identifier: "cancel")
        cancel.keyEquivalent = "\u{1b}"
        saveButton = button("Save", action: #selector(save), identifier: "save")
        saveButton.keyEquivalent = "\r"
        let actions = NativeSheetChrome.actions(leading: [defaults], trailing: [cancel, saveButton])

        let stack = NSStackView(views: [heading, group, diskNote, validation, actions])
        stack.spacing = 8
        stack.setCustomSpacing(16, after: heading)
        stack.setCustomSpacing(6, after: group)
        stack.setCustomSpacing(12, after: validation)
        NativeSheetChrome.install(stack, in: window, width: width)
    }

    private func button(_ title: String, action: Selector, identifier: String) -> NSButton {
        let button = NativeSheetChrome.button(title, target: self, action: action)
        button.identifier = NSUserInterfaceItemIdentifier("vm-resources-\(identifier)")
        return button
    }

    func controlTextDidChange(_ notification: Notification) { updateValidation() }

    @objc private func changeResources() { updateValidation() }

    @objc private func cancel() { dismiss() }

    @objc private func save() {
        guard let resources = try? draft() else { return }
        saveHandler(resources)
        dismiss()
    }

    @objc private func useDefaults() { setFields(limits.defaults) }

    private func setFields(_ resources: VMResources) {
        cpuPopup.selectItem(withTag: resources.cpuCount)
        memoryPopup.selectItem(withTag: resources.memoryGiB)
        diskField.stringValue = String(max(resources.diskGiB ?? minimumDiskGiB, minimumDiskGiB))
        updateValidation()
    }

    private func draft() throws -> VMResources {
        try limits.validate(
            cpuCount: String(cpuPopup.selectedItem?.tag ?? 0),
            memoryGiB: String(memoryPopup.selectedItem?.tag ?? 0),
            diskGiB: diskField.stringValue, minimumDiskGiB: minimumDiskGiB
        )
    }

    private func updateValidation() {
        do {
            let resources = try draft()
            let memoryMiB = resources.memoryGiB * 1024
            validationLabel.textColor = .secondaryLabelColor
            validationLabel.stringValue = MemoryPolicy.maySlowHost(
                memoryMiB: memoryMiB, hostMemoryMiB: limits.hostMemoryMiB
            ) ? "This leaves \(MemoryPolicy.displayLabel(memoryMiB: limits.hostMemoryMiB - memoryMiB)) for macOS and may slow other apps." : ""
            saveButton.isEnabled = true
        } catch {
            validationLabel.textColor = .systemRed
            validationLabel.stringValue = error.localizedDescription
            saveButton.isEnabled = false
        }
    }
}
