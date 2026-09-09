import AppKit

/// Edits a draft; only Save publishes it to the next VM launch.
@MainActor
final class VMResourceEditor: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    private let limits: VMResourceLimits
    private let saveHandler: (VMResources) -> Void
    private let closeHandler: () -> Void
    private(set) var window: NSWindow!
    private let cpuField = NSTextField()
    private let memoryPopup = NSPopUpButton()
    private let cpuStepper = NSStepper()
    private let validationLabel = NSTextField(wrappingLabelWithString: "")
    private var saveButton: OmarchyActionButton!
    private var didClose = false

    init(
        resources: VMResources,
        limits: VMResourceLimits,
        save: @escaping (VMResources) -> Void,
        didClose: @escaping () -> Void
    ) {
        self.limits = limits
        saveHandler = save
        closeHandler = didClose
        super.init()
        buildWindow()
        setFields(limits.resolve(resources))
    }

    func beginSheet(for parent: NSWindow) {
        parent.beginSheet(window)
        window.makeFirstResponder(cpuField)
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

    func controlTextDidChange(_ notification: Notification) {
        updateValidation()
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 382),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Virtual machine resources"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = OmarchyStartMenuTheme.background
        window.delegate = self
        window.setAccessibilityLabel("Virtual machine resources")

        let title = label("Resources", size: 22, weight: .bold)
        let explanation = label(
            "This Mac has \(limits.hostCPUCount) processor cores and \(limits.hostMemoryBytes / VMResourceLimits.bytesPerGiB) GiB of memory. Changes apply on the next launch.",
            size: 11, muted: true
        )
        let heading = NSStackView(views: [title, explanation])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 8
        explanation.widthAnchor.constraint(equalTo: heading.widthAnchor).isActive = true

        cpuField.delegate = self
        cpuField.identifier = NSUserInterfaceItemIdentifier("vm-resources-cpu")
        cpuField.setAccessibilityLabel("Processor cores")
        cpuField.setAccessibilityHelp("Whole number from \(limits.cpuRange.lowerBound) to \(limits.cpuRange.upperBound)")
        cpuField.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        cpuField.textColor = OmarchyStartMenuTheme.foreground
        cpuField.backgroundColor = OmarchyStartMenuTheme.background
        cpuField.alignment = .center
        cpuField.widthAnchor.constraint(equalToConstant: 76).isActive = true
        cpuStepper.minValue = Double(limits.cpuRange.lowerBound)
        cpuStepper.maxValue = Double(limits.cpuRange.upperBound)
        cpuStepper.increment = 1
        cpuStepper.valueWraps = false
        cpuStepper.target = self
        cpuStepper.action = #selector(step)
        cpuStepper.setAccessibilityLabel("Processor cores")
        cpuStepper.identifier = NSUserInterfaceItemIdentifier("vm-resources-cpu-stepper")
        let cpuControls = NSStackView(views: [cpuField, cpuStepper])
        cpuControls.spacing = 8

        for choice in limits.memoryChoicesGiB {
            memoryPopup.addItem(withTitle: choice == VMResourceLimits.defaultMemoryGiB
                ? "\(choice) GiB · default" : "\(choice) GiB")
            memoryPopup.lastItem?.tag = choice
        }
        memoryPopup.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        memoryPopup.target = self
        memoryPopup.action = #selector(changeMemory)
        memoryPopup.isEnabled = limits.memoryChoicesGiB.count > 1
        memoryPopup.identifier = NSUserInterfaceItemIdentifier("vm-resources-memory")
        memoryPopup.setAccessibilityLabel("Memory")
        memoryPopup.setAccessibilityHelp("Larger allocations leave at least 8 GiB for macOS")

        let cpuRow = resourceRow(
            title: "Processor cores", detail: "4–\(limits.cpuRange.upperBound) cores · all cores available", control: cpuControls
        )
        let memoryRow = resourceRow(
            title: "Memory", detail: "Larger allocations leave 8 GiB for macOS", control: memoryPopup
        )
        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = OmarchyStartMenuTheme.separator.cgColor
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let rows = NSStackView(views: [cpuRow, separator, memoryRow])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = OmarchyStartMenuTheme.darkBackground.cgColor
        card.layer?.cornerRadius = 8
        card.layer?.borderWidth = 1
        card.layer?.borderColor = OmarchyStartMenuTheme.border.cgColor
        card.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            rows.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            rows.topAnchor.constraint(equalTo: card.topAnchor),
            rows.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            cpuRow.widthAnchor.constraint(equalTo: rows.widthAnchor),
            memoryRow.widthAnchor.constraint(equalTo: rows.widthAnchor),
            separator.widthAnchor.constraint(equalTo: rows.widthAnchor),
        ])

        validationLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        validationLabel.textColor = OmarchyStartMenuTheme.danger
        validationLabel.identifier = NSUserInterfaceItemIdentifier("vm-resources-validation")
        validationLabel.setAccessibilityElement(true)
        validationLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true

        let defaults = button("Use Defaults", style: .secondary, action: #selector(useDefaults), identifier: "defaults")
        let cancel = button("Cancel", style: .secondary, action: #selector(cancel), identifier: "cancel")
        cancel.keyEquivalent = "\u{1b}"
        saveButton = button("Save", style: .primary, action: #selector(save), identifier: "save")
        saveButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [defaults, spacer, cancel, saveButton])
        actions.spacing = 8

        let stack = NSStackView(views: [heading, card, validationLabel, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = OmarchyStartMenuTheme.background.cgColor
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 38),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor),
            card.widthAnchor.constraint(equalTo: stack.widthAnchor),
            validationLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func label(
        _ text: String, size: CGFloat, weight: NSFont.Weight = .regular, muted: Bool = false
    ) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .monospacedSystemFont(ofSize: size, weight: weight)
        field.textColor = muted ? OmarchyStartMenuTheme.muted : OmarchyStartMenuTheme.foreground
        return field
    }

    private func resourceRow(title: String, detail: String, control: NSView) -> NSView {
        let labels = NSStackView(views: [
            label(title, size: 13, weight: .bold),
            label(detail, size: 10, muted: true),
        ])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 5
        let row = NSView()
        labels.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(labels)
        row.addSubview(control)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 72),
            labels.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            labels.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -16),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    private func button(
        _ title: String, style: OmarchyControlStyle, action: Selector, identifier: String
    ) -> OmarchyActionButton {
        let button = OmarchyActionButton(title: title, style: style, target: self, action: action)
        button.identifier = NSUserInterfaceItemIdentifier("vm-resources-\(identifier)")
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        button.widthAnchor.constraint(equalToConstant: identifier == "defaults" ? 130 : 82).isActive = true
        return button
    }

    @objc private func step() {
        cpuField.stringValue = String(cpuStepper.integerValue)
        updateValidation()
    }

    @objc private func changeMemory() { updateValidation() }

    @objc private func cancel() { dismiss() }

    @objc private func save() {
        guard let resources = try? draft() else { return }
        saveHandler(resources)
        dismiss()
    }

    @objc private func useDefaults() { setFields(limits.defaults) }

    private func setFields(_ resources: VMResources) {
        cpuField.stringValue = String(resources.cpuCount)
        memoryPopup.selectItem(withTag: resources.memoryGiB)
        updateValidation()
    }

    private func draft() throws -> VMResources {
        try limits.validate(
            cpuCount: cpuField.stringValue,
            memoryGiB: String(memoryPopup.selectedItem?.tag ?? 0)
        )
    }

    private func updateValidation() {
        if let cpus = Int(cpuField.stringValue), limits.cpuRange.contains(cpus) {
            cpuStepper.integerValue = cpus
        }
        do {
            _ = try draft()
            validationLabel.stringValue = ""
            saveButton.isEnabled = true
        } catch {
            validationLabel.stringValue = error.localizedDescription
            saveButton.isEnabled = false
        }
    }
}
