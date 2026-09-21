import AppKit

/// Edits a draft; only Save publishes it to the next VM launch.
@MainActor
final class VMResourceEditor: NSObject, NSWindowDelegate {
    private let limits: VMResourceLimits
    private let saveHandler: (VMResources) -> Void
    private let closeHandler: () -> Void
    private(set) var window: NSWindow!
    private let cpuPopup = NSPopUpButton()
    private let memoryPopup = NSPopUpButton()
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

        for choice in limits.cpuRange {
            let suffix = choice == limits.defaults.cpuCount
                ? " · default"
                : choice == limits.cpuRange.upperBound ? " · all cores" : ""
            cpuPopup.addItem(withTitle: "\(choice) cores\(suffix)")
            cpuPopup.lastItem?.tag = choice
        }
        cpuPopup.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
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
        memoryPopup.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        memoryPopup.target = self
        memoryPopup.action = #selector(changeResources)
        memoryPopup.isEnabled = limits.memoryChoicesGiB.count > 1
        memoryPopup.identifier = NSUserInterfaceItemIdentifier("vm-resources-memory")
        memoryPopup.setAccessibilityLabel("Memory")
        memoryPopup.setAccessibilityHelp("Higher allocations may affect macOS performance; at least 4 GiB stays available to macOS")

        let cpuRow = resourceRow(
            title: "Processor cores",
            detail: "Shared with macOS. More cores may help demanding workloads.",
            control: cpuPopup
        )
        let memoryRow = resourceRow(
            title: "Memory", detail: "Shared with macOS", control: memoryPopup
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
            cpuPopup.widthAnchor.constraint(equalTo: memoryPopup.widthAnchor),
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
        updateValidation()
    }

    private func draft() throws -> VMResources {
        try limits.validate(
            cpuCount: String(cpuPopup.selectedItem?.tag ?? 0),
            memoryGiB: String(memoryPopup.selectedItem?.tag ?? 0)
        )
    }

    private func updateValidation() {
        do {
            let resources = try draft()
            let memoryMiB = resources.memoryGiB * 1024
            validationLabel.textColor = OmarchyStartMenuTheme.muted
            validationLabel.stringValue = MemoryPolicy.maySlowHost(
                memoryMiB: memoryMiB, hostMemoryMiB: limits.hostMemoryMiB
            ) ? "This leaves \(MemoryPolicy.displayLabel(memoryMiB: limits.hostMemoryMiB - memoryMiB)) for macOS and may slow other apps." : ""
            saveButton.isEnabled = true
        } catch {
            validationLabel.textColor = OmarchyStartMenuTheme.danger
            validationLabel.stringValue = error.localizedDescription
            saveButton.isEnabled = false
        }
    }
}
