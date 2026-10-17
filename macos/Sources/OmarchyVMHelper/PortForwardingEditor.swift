import AppKit
import Foundation

/// A fixed-size editor keeps a growing forwarding list out of the launch menu.
/// Rows scroll independently once they no longer fit in the sheet.
@MainActor
final class PortForwardingEditor: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    typealias SaveHandler = ([PortForwardMapping]) -> String?

    private enum FieldKind: Int {
        case host = 0
        case guest = 1
    }

    private let saveHandler: SaveHandler
    private let closeHandler: () -> Void
    private var model: PortForwardingEditorModel

    private(set) var window: NSWindow!
    private let rowsStack = NSStackView()
    private let scrollView = NSScrollView()
    private let addButton = NSButton()
    private let addSSHButton = NSButton()
    private let saveButton = NSButton()
    private let validationLabel = NSTextField(wrappingLabelWithString: "")
    private var announcedValidationError: String?

    init(
        mappings: [PortForwardMapping],
        save: @escaping SaveHandler,
        didClose: @escaping () -> Void = {}
    ) {
        saveHandler = save
        closeHandler = didClose
        model = PortForwardingEditorModel(mappings: mappings)
        super.init()
        buildWindow()
        rebuildRows()
    }

    func beginSheet(for parent: NSWindow) {
        parent.beginSheet(window)
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        closeWindow()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closeWindow()
        return false
    }

    private func buildWindow() {
        let width: CGFloat = 540
        window = NativeSheetChrome.window(title: "Port Forwarding", width: width)
        window.delegate = self

        let explanation = NSTextField(
            wrappingLabelWithString: "Mac → Omarchy mappings expose guest services on Mac localhost. For Omarchy → Mac, connect to \(PortForwardPolicy.guestToHostAddress)."
        )
        explanation.maximumNumberOfLines = 2
        explanation.identifier = NSUserInterfaceItemIdentifier("port-forward-explanation")
        let heading = NativeSheetChrome.header(
            symbol: "arrow.left.arrow.right", color: .systemIndigo,
            title: "Port Forwarding", subtitle: explanation
        )

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rowsStack)
        NSLayoutConstraint.activate([
            rowsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: document.topAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])

        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.identifier = NSUserInterfaceItemIdentifier("port-forward-scroll")
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 224),
        ])
        let list = FormGroupView()
        list.embed(scrollView)

        configureAddButton(addButton, title: "Add Port", symbol: "plus", action: #selector(addPort),
                           identifier: "port-forward-add",
                           help: "Adds another localhost-to-Omarchy port mapping")
        configureAddButton(addSSHButton, title: "Add SSH", symbol: "terminal", action: #selector(addSSH),
                           identifier: "port-forward-add-ssh",
                           help: "Adds localhost:2222 to Omarchy:22 over TCP")

        NativeSheetChrome.styleFootnote(validationLabel)
        validationLabel.maximumNumberOfLines = 2
        validationLabel.identifier = NSUserInterfaceItemIdentifier("port-forward-validation")
        validationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let addActions = NSStackView(views: [addButton, addSSHButton])
        addActions.orientation = .horizontal
        addActions.alignment = .centerY
        addActions.spacing = 8

        let validation = NativeSheetChrome.inset(validationLabel)
        validation.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true

        let cancelButton = NativeSheetChrome.button("Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.identifier = NSUserInterfaceItemIdentifier("port-forward-cancel")

        saveButton.title = "Save"
        saveButton.bezelStyle = .push
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.identifier = NSUserInterfaceItemIdentifier("port-forward-save")

        let actions = NativeSheetChrome.actions(leading: [addActions], trailing: [cancelButton, saveButton])

        let stack = NSStackView(views: [heading, list, validation, actions])
        stack.spacing = 6
        stack.setCustomSpacing(16, after: heading)
        stack.setCustomSpacing(12, after: validation)
        NativeSheetChrome.install(stack, in: window, width: width)
    }

    private func configureAddButton(
        _ button: NSButton, title: String, symbol: String, action: Selector,
        identifier: String, help: String
    ) {
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.bezelStyle = .push
        button.controlSize = .regular
        button.target = self
        button.action = action
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityHelp(help)
    }

    private func rebuildRows(
        focusRow: Int? = nil,
        focusAddButton: Bool = false,
        scrollToBottom: Bool = false
    ) {
        for view in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if model.drafts.isEmpty {
            addFullWidthArrangedSubview(emptyState())
        } else {
            for index in model.drafts.indices {
                if index > model.drafts.startIndex {
                    addInsetSeparator()
                }
                addFullWidthArrangedSubview(mappingRow(at: index))
            }
        }

        updateValidation()
        rowsStack.layoutSubtreeIfNeeded()
        scrollView.documentView?.layoutSubtreeIfNeeded()

        if let index = focusRow,
           let field = descendant(
               withIdentifier: "port-forward-host-\(index)",
               in: rowsStack
            ) as? NSTextField {
            window.makeFirstResponder(field)
            reveal(field: field, atBottom: scrollToBottom)
            // Repeat after AppKit's next layout pass in case the document grew.
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field, field.window === self.window else { return }
                self.reveal(field: field, atBottom: scrollToBottom)
            }
        } else if focusAddButton {
            window.makeFirstResponder(addButton)
        }
    }

    private func emptyState() -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "network", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .regular)
        icon.contentTintColor = .tertiaryLabelColor

        let title = NSTextField(labelWithString: "No ports forwarded")
        title.font = .systemFont(ofSize: 14, weight: .semibold)

        let detail = NSTextField(
            wrappingLabelWithString: "Add a port for a guest service listening beyond guest localhost."
        )
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.maximumNumberOfLines = 2

        let stack = NSStackView(views: [icon, title, detail])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.identifier = NSUserInterfaceItemIdentifier("port-forward-empty")
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -30),
        ])
        return container
    }

    private func mappingRow(at index: Int) -> NSView {
        let draft = model.drafts[index]
        let localhost = secondaryLabel("localhost:")
        let hostField = portField(value: draft.hostPort, index: index, kind: .host)
        let arrow = secondaryLabel("→")
        arrow.alignment = .center
        let guest = secondaryLabel("Omarchy:")
        let guestField = portField(value: draft.guestPort, index: index, kind: .guest)

        let protocolPicker = NSPopUpButton(frame: .zero, pullsDown: false)
        protocolPicker.addItems(withTitles: PortForwardProtocol.allCases.map(\.displayName))
        protocolPicker.selectItem(withTitle: draft.protocol.displayName)
        protocolPicker.controlSize = .regular
        protocolPicker.target = self
        protocolPicker.action = #selector(protocolChanged(_:))
        protocolPicker.tag = index
        protocolPicker.identifier = NSUserInterfaceItemIdentifier("port-forward-protocol-\(index)")
        protocolPicker.setAccessibilityLabel("Protocol for mapping \(index + 1)")
        protocolPicker.widthAnchor.constraint(equalToConstant: 72).isActive = true

        let remove = NSButton(
            image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: nil) ?? NSImage(),
            target: self,
            action: #selector(removePort(_:))
        )
        remove.isBordered = false
        remove.contentTintColor = .secondaryLabelColor
        remove.tag = index
        remove.identifier = NSUserInterfaceItemIdentifier("port-forward-remove-\(index)")
        remove.setAccessibilityLabel("Remove mapping \(index + 1)")
        remove.toolTip = "Remove this mapping"
        remove.widthAnchor.constraint(equalToConstant: 28).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let rowStack = NSStackView(
            views: [localhost, hostField, arrow, guest, guestField, protocolPicker, spacer, remove]
        )
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = 7
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        let row = NSView()
        row.identifier = NSUserInterfaceItemIdentifier("port-forward-row-\(index)")
        row.addSubview(rowStack)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 48),
            rowStack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: NativeSheetChrome.rowInset),
            rowStack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -6),
            rowStack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    private func portField(value: String, index: Int, kind: FieldKind) -> NSTextField {
        let field = NSTextField(string: value)
        field.placeholderString = kind == .host ? "8080" : "3000"
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.controlSize = .regular
        field.delegate = self
        field.tag = (index * 2) + kind.rawValue
        field.identifier = NSUserInterfaceItemIdentifier(
            kind == .host ? "port-forward-host-\(index)" : "port-forward-guest-\(index)"
        )
        field.setAccessibilityLabel(
            kind == .host
                ? "Mac port for mapping \(index + 1)"
                : "Omarchy port for mapping \(index + 1)"
        )
        field.widthAnchor.constraint(equalToConstant: 72).isActive = true
        return field
    }

    private func secondaryLabel(_ value: String) -> NSTextField {
        let field = NSTextField(labelWithString: value)
        field.font = .systemFont(ofSize: 12)
        field.textColor = .secondaryLabelColor
        field.setContentHuggingPriority(.required, for: .horizontal)
        return field
    }

    private func addInsetSeparator() {
        let separator = NativeSheetChrome.separator()
        rowsStack.addArrangedSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: rowsStack.leadingAnchor, constant: NativeSheetChrome.rowInset),
            separator.trailingAnchor.constraint(equalTo: rowsStack.trailingAnchor, constant: -NativeSheetChrome.rowInset),
        ])
    }

    private func addFullWidthArrangedSubview(_ view: NSView) {
        rowsStack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let index = field.tag / 2
        guard model.drafts.indices.contains(index), let kind = FieldKind(rawValue: field.tag % 2) else {
            return
        }
        switch kind {
        case .host:
            model.updateHostPort(field.stringValue, at: index)
        case .guest:
            model.updateGuestPort(field.stringValue, at: index)
        }
        updateValidation()
    }

    @objc private func protocolChanged(_ sender: NSPopUpButton) {
        guard model.drafts.indices.contains(sender.tag),
              let rawValue = sender.titleOfSelectedItem?.lowercased(),
              let protocolValue = PortForwardProtocol(rawValue: rawValue) else { return }
        model.updateProtocol(protocolValue, at: sender.tag)
        updateValidation()
    }

    @objc private func addPort() {
        guard let index = model.addEmptyMapping() else { return }
        rebuildRows(
            focusRow: index,
            scrollToBottom: true
        )
    }

    @objc private func addSSH() {
        guard let index = model.addSSHPreset() else { return }
        rebuildRows(
            focusRow: index,
            scrollToBottom: true
        )
    }

    @objc private func removePort(_ sender: NSButton) {
        guard model.drafts.indices.contains(sender.tag) else { return }
        let removedIndex = sender.tag
        model.removeMapping(at: removedIndex)
        if model.drafts.isEmpty {
            rebuildRows(focusAddButton: true)
        } else {
            rebuildRows(
                focusRow: min(removedIndex, model.drafts.index(before: model.drafts.endIndex))
            )
        }
    }

    @objc private func cancel() {
        closeWindow()
    }

    @objc private func save() {
        let validation = validation()
        guard let mappings = validation.mappings else {
            updateValidation()
            return
        }
        if let problem = saveHandler(mappings) {
            validationLabel.stringValue = problem
            validationLabel.textColor = .systemRed
            saveButton.isEnabled = false
            return
        }
        closeWindow()
    }

    private func updateValidation() {
        let validation = validation()
        validationLabel.stringValue = validation.message
        validationLabel.isHidden = validation.message.isEmpty
        validationLabel.textColor = validation.isError ? .systemRed : .secondaryLabelColor
        if validation.isError, announcedValidationError != validation.message {
            announcedValidationError = validation.message
            NSAccessibility.post(
                element: validationLabel,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: validation.message,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        } else if !validation.isError {
            announcedValidationError = nil
        }
        saveButton.isEnabled = validation.canSave
        let canAddMapping = model.canAddMapping
        addButton.isEnabled = canAddMapping
        addSSHButton.isEnabled = canAddMapping
        let addLimitToolTip = canAddMapping
            ? nil
            : "Up to \(PortForwardPolicy.maximumMappings) mappings are supported"
        addButton.toolTip = addLimitToolTip ?? "Add a port mapping"
        addSSHButton.toolTip = addLimitToolTip ?? "Add an SSH port mapping"
    }

    private func validation() -> PortForwardingEditorValidation {
        model.validation
    }

    private func closeWindow() {
        if let parent = window.sheetParent {
            parent.endSheet(window)
        }
        window.orderOut(nil)
        closeHandler()
    }

    private func reveal(field: NSTextField, atBottom: Bool) {
        window.contentView?.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        scrollView.documentView?.layoutSubtreeIfNeeded()
        if atBottom {
            let documentHeight = scrollView.documentView?.frame.height
                ?? rowsStack.frame.height
            scrollView.contentView.scroll(
                to: NSPoint(
                    x: 0,
                    y: max(0, documentHeight - scrollView.contentView.bounds.height)
                )
            )
        } else if let document = scrollView.documentView {
            document.scrollToVisible(field.convert(field.bounds, to: document))
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func descendant(withIdentifier value: String, in root: NSView) -> NSView? {
        if root.identifier?.rawValue == value { return root }
        for child in root.subviews {
            if let match = descendant(withIdentifier: value, in: child) {
                return match
            }
        }
        return nil
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
