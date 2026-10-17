import AppKit

/// Edits a draft; only Save publishes it.
@MainActor
final class KeyboardRoutingEditor: NSObject, NSWindowDelegate {
    private let saveHandler: (KeyboardRoutingPreferences) -> Void
    private let closeHandler: () -> Void
    private(set) var window: NSWindow!
    private let brightnessPopup = NSPopUpButton()
    private let missionControlPopup = NSPopUpButton()
    private let spotlightPopup = NSPopUpButton()
    private let dictationPopup = NSPopUpButton()
    private let doNotDisturbPopup = NSPopUpButton()
    private var didClose = false

    init(
        preferences: KeyboardRoutingPreferences,
        save: @escaping (KeyboardRoutingPreferences) -> Void,
        didClose: @escaping () -> Void
    ) {
        saveHandler = save
        closeHandler = didClose
        super.init()
        buildWindow()
        setFields(preferences)
    }

    func beginSheet(for parent: NSWindow) {
        parent.beginSheet(window)
        window.makeFirstResponder(brightnessPopup)
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
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 570),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Keyboard"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = OmarchyStartMenuTheme.background
        window.delegate = self
        window.setAccessibilityLabel("Keyboard")

        let title = label("Keyboard", size: 22, weight: .bold)
        let explanation = label(
            "Choose which side gets the Mac's dedicated keys while Omarchy is focused. Changes apply on the next launch.",
            size: 11, muted: true
        )
        let heading = NSStackView(views: [title, explanation])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 8
        explanation.widthAnchor.constraint(equalTo: heading.widthAnchor).isActive = true

        configure(brightnessPopup, identifier: "brightness", accessibilityLabel: "Brightness keys")
        configure(missionControlPopup, identifier: "mission-control", accessibilityLabel: "Mission Control key")
        configure(spotlightPopup, identifier: "spotlight", accessibilityLabel: "Spotlight or Launchpad key")
        configure(dictationPopup, identifier: "dictation", accessibilityLabel: "Dictation or Siri key")
        configure(doNotDisturbPopup, identifier: "do-not-disturb", accessibilityLabel: "Do Not Disturb key")

        let rowViews = [
            routeRow(
                title: "Brightness",
                detail: "Display brightness down and up (F1, F2). Built-in Mac keyboards always keep these with macOS.",
                control: brightnessPopup
            ),
            routeRow(title: "Mission Control", detail: "The F3 key", control: missionControlPopup),
            routeRow(title: "Spotlight / Launchpad", detail: "The F4 key", control: spotlightPopup),
            routeRow(
                title: "Dictation / Siri",
                detail: "The F5 key on built-in Mac keyboards",
                control: dictationPopup
            ),
            routeRow(
                title: "Do Not Disturb",
                detail: "The F6 key on built-in Mac keyboards",
                control: doNotDisturbPopup
            ),
        ]
        var stacked: [NSView] = []
        for (index, row) in rowViews.enumerated() {
            if index > 0 { stacked.append(separator()) }
            stacked.append(row)
        }
        let rows = NSStackView(views: stacked)
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
        ])
        for view in stacked {
            view.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }

        let note = label(
            "Volume and mute always stay with macOS. With \"Use F1, F2, etc. as standard function keys\" on, these keys reach Omarchy as F-keys.",
            size: 11, muted: true
        )

        let defaults = button("Use Defaults", style: .secondary, action: #selector(useDefaults), identifier: "defaults")
        let cancel = button("Cancel", style: .secondary, action: #selector(cancel), identifier: "cancel")
        cancel.keyEquivalent = "\u{1b}"
        let save = button("Save", style: .primary, action: #selector(save), identifier: "save")
        save.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [defaults, spacer, cancel, save])
        actions.spacing = 8

        let stack = NSStackView(views: [heading, card, note, actions])
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
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func configure(_ popup: NSPopUpButton, identifier: String, accessibilityLabel: String) {
        popup.addItem(withTitle: "macOS")
        popup.lastItem?.tag = 0
        popup.addItem(withTitle: "Omarchy")
        popup.lastItem?.tag = 1
        popup.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        popup.identifier = NSUserInterfaceItemIdentifier("keyboard-routing-\(identifier)")
        popup.setAccessibilityLabel(accessibilityLabel)
    }

    private func label(
        _ text: String, size: CGFloat, weight: NSFont.Weight = .regular, muted: Bool = false
    ) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .monospacedSystemFont(ofSize: size, weight: weight)
        field.textColor = muted ? OmarchyStartMenuTheme.muted : OmarchyStartMenuTheme.foreground
        return field
    }

    private func separator() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = OmarchyStartMenuTheme.separator.cgColor
        view.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return view
    }

    private func routeRow(title: String, detail: String, control: NSView) -> NSView {
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
            row.heightAnchor.constraint(equalToConstant: 64),
            labels.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            labels.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -16),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.widthAnchor.constraint(equalToConstant: 130),
        ])
        return row
    }

    private func button(
        _ title: String, style: OmarchyControlStyle, action: Selector, identifier: String
    ) -> OmarchyActionButton {
        let button = OmarchyActionButton(title: title, style: style, target: self, action: action)
        button.identifier = NSUserInterfaceItemIdentifier("keyboard-routing-\(identifier)")
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        button.widthAnchor.constraint(equalToConstant: identifier == "defaults" ? 130 : 82).isActive = true
        return button
    }

    @objc private func cancel() { dismiss() }

    @objc private func save() {
        saveHandler(draft())
        dismiss()
    }

    @objc private func useDefaults() { setFields(.defaults) }

    private func setFields(_ preferences: KeyboardRoutingPreferences) {
        brightnessPopup.selectItem(withTag: Self.tag(preferences.brightness))
        missionControlPopup.selectItem(withTag: Self.tag(preferences.missionControl))
        spotlightPopup.selectItem(withTag: Self.tag(preferences.spotlight))
        dictationPopup.selectItem(withTag: Self.tag(preferences.dictation))
        doNotDisturbPopup.selectItem(withTag: Self.tag(preferences.doNotDisturb))
    }

    private func draft() -> KeyboardRoutingPreferences {
        KeyboardRoutingPreferences(
            brightness: Self.route(brightnessPopup),
            missionControl: Self.route(missionControlPopup),
            spotlight: Self.route(spotlightPopup),
            dictation: Self.route(dictationPopup),
            doNotDisturb: Self.route(doNotDisturbPopup)
        )
    }

    private static func tag(_ route: KeyRoute) -> Int { route == .omarchy ? 1 : 0 }

    private static func route(_ popup: NSPopUpButton) -> KeyRoute {
        popup.selectedItem?.tag == 1 ? .omarchy : .macOS
    }
}
