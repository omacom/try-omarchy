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
    private let mediaPopup = NSPopUpButton()
    private let addShortcutPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let shortcutsContainer = NSView()
    private let recorder = ShortcutRecorder()
    private let picks: [MacSystemShortcuts.Pick]
    private(set) var shortcuts: [KeptShortcut] = []
    private var didClose = false

    private static let rowsBeforeScrolling = 6
    private static let scrollingListHeight: CGFloat = 5.5 * 41

    init(
        preferences: KeyboardRoutingPreferences,
        picks: [MacSystemShortcuts.Pick] = MacSystemShortcuts.picks(),
        save: @escaping (KeyboardRoutingPreferences) -> Void,
        didClose: @escaping () -> Void
    ) {
        saveHandler = save
        closeHandler = didClose
        self.picks = picks
        shortcuts = preferences.shortcuts
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
        recorder.stop()
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
        window = NativeSheetChrome.window(title: "Keyboard", width: width)
        window.delegate = self

        let heading = NativeSheetChrome.header(
            symbol: "keyboard", color: .systemGray, title: "Keyboard",
            subtitle: "Choose which side gets the Mac's dedicated keys and shortcuts while Omarchy is focused. Changes apply on the next launch."
        )

        configure(brightnessPopup, identifier: "brightness", accessibilityLabel: "Brightness keys")
        configure(missionControlPopup, identifier: "mission-control", accessibilityLabel: "Mission Control key")
        configure(spotlightPopup, identifier: "spotlight", accessibilityLabel: "Spotlight or Launchpad key")
        configure(dictationPopup, identifier: "dictation", accessibilityLabel: "Dictation or Siri key")
        configure(doNotDisturbPopup, identifier: "do-not-disturb", accessibilityLabel: "Do Not Disturb key")
        configure(mediaPopup, identifier: "media", accessibilityLabel: "Media keys")

        let group = NativeSheetChrome.group([
            NativeSheetChrome.row(
                title: "Brightness",
                detail: "Display brightness down and up (F1, F2). Built-in Mac keyboards always keep these with macOS.",
                control: brightnessPopup
            ),
            NativeSheetChrome.row(title: "Mission Control", detail: "The F3 key", control: missionControlPopup),
            NativeSheetChrome.row(title: "Spotlight / Launchpad", detail: "The F4 key", control: spotlightPopup),
            NativeSheetChrome.row(
                title: "Dictation / Siri",
                detail: "The F5 key on built-in Mac keyboards",
                control: dictationPopup
            ),
            NativeSheetChrome.row(
                title: "Do Not Disturb",
                detail: "The F6 key on built-in Mac keyboards",
                control: doNotDisturbPopup
            ),
            NativeSheetChrome.row(
                title: "Media",
                detail: "Previous, play/pause, next (F7–F9). Only while Omarchy is focused.",
                control: mediaPopup
            ),
        ])
        for popup in [missionControlPopup, spotlightPopup, dictationPopup, doNotDisturbPopup, mediaPopup] {
            popup.widthAnchor.constraint(equalTo: brightnessPopup.widthAnchor).isActive = true
        }
        brightnessPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true

        let note = NativeSheetChrome.footnote(
            "Volume and mute always stay with macOS. With \"Use F1, F2, etc. as standard function keys\" on, these keys reach Omarchy as F-keys."
        )

        let shortcutsTitle = NativeSheetChrome.sectionTitle("Shortcuts")
        configureAddShortcutPopup()
        let shortcutsNote = NativeSheetChrome.footnote(
            "Shortcuts kept with macOS never reach Omarchy. Keeping Switch Spaces gives up Control–arrow word movement in Omarchy."
        )

        let defaults = button("Use Defaults", action: #selector(useDefaults), identifier: "defaults")
        let cancel = button("Cancel", action: #selector(cancel), identifier: "cancel")
        cancel.keyEquivalent = "\u{1b}"
        let save = button("Save", action: #selector(save), identifier: "save")
        save.keyEquivalent = "\r"
        let actions = NativeSheetChrome.actions(leading: [defaults], trailing: [cancel, save])

        let stack = NSStackView(views: [heading, group, note, shortcutsTitle, shortcutsContainer, shortcutsNote, actions])
        stack.spacing = 8
        stack.setCustomSpacing(16, after: heading)
        stack.setCustomSpacing(6, after: group)
        stack.setCustomSpacing(16, after: note)
        stack.setCustomSpacing(6, after: shortcutsContainer)
        stack.setCustomSpacing(12, after: shortcutsNote)
        rebuildShortcuts()
        NativeSheetChrome.install(stack, in: window, width: width)
    }

    private func configureAddShortcutPopup() {
        addShortcutPopup.identifier = NSUserInterfaceItemIdentifier("keyboard-routing-add-shortcut")
        addShortcutPopup.setAccessibilityLabel("Add a shortcut kept with macOS")
        addShortcutPopup.target = self
        addShortcutPopup.action = #selector(addShortcut(_:))
    }

    private func refreshAddShortcutMenu() {
        addShortcutPopup.removeAllItems()
        addShortcutPopup.addItem(withTitle: recorder.isRecording ? "Recording…" : "Add")
        let isFull = shortcuts.count >= KeyboardRoutingPreferences.maximumShortcuts
        for (index, pick) in picks.enumerated() {
            let symbols = pick.shortcuts.map(\.symbols).joined(separator: " ")
            addShortcutPopup.addItem(withTitle: "\(pick.title)  \(symbols)")
            let item = addShortcutPopup.lastItem
            item?.tag = index
            item?.isEnabled = !isFull && !pick.shortcuts.allSatisfy(isKept)
        }
        if !picks.isEmpty { addShortcutPopup.menu?.addItem(.separator()) }
        addShortcutPopup.addItem(withTitle: "Record Shortcut…")
        addShortcutPopup.lastItem?.tag = Self.recordTag
        addShortcutPopup.lastItem?.isEnabled = !isFull
        addShortcutPopup.autoenablesItems = false
        addShortcutPopup.isEnabled = !recorder.isRecording
    }

    private static let recordTag = -1

    private func isKept(_ shortcut: KeptShortcut) -> Bool {
        shortcuts.contains { $0.isSameKeys(as: shortcut) }
    }

    private func rebuildShortcuts() {
        shortcutsContainer.subviews.forEach { $0.removeFromSuperview() }
        let rows = shortcuts.enumerated().map { index, shortcut in
            shortcutRow(shortcut, index: index)
        }
        let addDetail = recorder.isRecording
            ? "Press the shortcut to keep with macOS. Esc cancels."
            : "Choose one of macOS's shortcuts, or record another."
        let addRow = NativeSheetChrome.row(
            title: shortcuts.isEmpty ? "Omarchy gets every shortcut" : "Add a shortcut",
            detail: addDetail,
            control: addShortcutPopup
        )
        refreshAddShortcutMenu()
        let group = FormGroupView()
        if rows.count < Self.rowsBeforeScrolling {
            group.embed(NativeSheetChrome.rowStack(rows + [addRow]))
        } else {
            group.embed(NativeSheetChrome.rowStack([scrollingList(rows), addRow]))
        }
        group.translatesAutoresizingMaskIntoConstraints = false
        shortcutsContainer.addSubview(group)
        NSLayoutConstraint.activate([
            group.leadingAnchor.constraint(equalTo: shortcutsContainer.leadingAnchor),
            group.trailingAnchor.constraint(equalTo: shortcutsContainer.trailingAnchor),
            group.topAnchor.constraint(equalTo: shortcutsContainer.topAnchor),
            group.bottomAnchor.constraint(equalTo: shortcutsContainer.bottomAnchor),
        ])
    }

    private func scrollingList(_ rows: [NSView]) -> NSScrollView {
        let stack = NativeSheetChrome.rowStack(rows)
        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scrollView = NSScrollView()
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: Self.scrollingListHeight),
        ])
        return scrollView
    }

    private func shortcutRow(_ shortcut: KeptShortcut, index: Int) -> NSView {
        let remove = NSButton(
            image: NSImage(systemSymbolName: "minus.circle.fill", accessibilityDescription: "Remove")!,
            target: self, action: #selector(removeShortcut(_:))
        )
        remove.isBordered = false
        remove.contentTintColor = .secondaryLabelColor
        remove.tag = index
        remove.identifier = NSUserInterfaceItemIdentifier("keyboard-routing-remove-shortcut-\(index)")
        remove.setAccessibilityLabel("Remove \(shortcut.name ?? shortcut.symbols)")
        guard let name = shortcut.name else {
            return NativeSheetChrome.row(title: shortcut.symbols, control: remove)
        }
        let symbols = NSTextField(labelWithString: shortcut.symbols)
        symbols.textColor = .secondaryLabelColor
        let control = NSStackView(views: [symbols, remove])
        control.orientation = .horizontal
        control.spacing = 8
        control.setHuggingPriority(.required, for: .horizontal)
        return NativeSheetChrome.row(title: name, control: control)
    }

    /// Rebuilds the list and grows or shrinks the sheet from its top edge.
    private func shortcutsChanged() {
        rebuildShortcuts()
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let contentRect = NSRect(origin: .zero, size: NSSize(width: content.frame.width, height: content.fittingSize.height))
        var frame = window.frame
        let size = window.frameRect(forContentRect: contentRect).size
        frame.origin.y += frame.height - size.height
        frame.size = size
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    func add(_ added: [KeptShortcut]) {
        for shortcut in added where !isKept(shortcut) && shortcuts.count < KeyboardRoutingPreferences.maximumShortcuts {
            shortcuts.append(shortcut)
        }
        shortcutsChanged()
    }

    @objc private func addShortcut(_ sender: NSPopUpButton) {
        guard let tag = sender.selectedItem?.tag else { return }
        if tag == Self.recordTag {
            recorder.start { [weak self] shortcut in
                guard let self else { return }
                if let shortcut { self.add([shortcut]) } else { self.shortcutsChanged() }
            }
            shortcutsChanged()
        } else if picks.indices.contains(tag) {
            add(picks[tag].shortcuts)
        }
    }

    @objc private func removeShortcut(_ sender: NSButton) {
        guard shortcuts.indices.contains(sender.tag) else { return }
        shortcuts.remove(at: sender.tag)
        shortcutsChanged()
    }

    private func configure(_ popup: NSPopUpButton, identifier: String, accessibilityLabel: String) {
        popup.addItem(withTitle: "macOS")
        popup.lastItem?.tag = 0
        popup.addItem(withTitle: "Omarchy")
        popup.lastItem?.tag = 1
        popup.identifier = NSUserInterfaceItemIdentifier("keyboard-routing-\(identifier)")
        popup.setAccessibilityLabel(accessibilityLabel)
    }

    private func button(_ title: String, action: Selector, identifier: String) -> NSButton {
        let button = NativeSheetChrome.button(title, target: self, action: action)
        button.identifier = NSUserInterfaceItemIdentifier("keyboard-routing-\(identifier)")
        return button
    }

    @objc private func cancel() { dismiss() }

    @objc private func save() {
        saveHandler(draft())
        dismiss()
    }

    @objc private func useDefaults() {
        recorder.stop()
        setFields(.defaults)
        shortcutsChanged()
    }

    private func setFields(_ preferences: KeyboardRoutingPreferences) {
        brightnessPopup.selectItem(withTag: Self.tag(preferences.brightness))
        missionControlPopup.selectItem(withTag: Self.tag(preferences.missionControl))
        spotlightPopup.selectItem(withTag: Self.tag(preferences.spotlight))
        dictationPopup.selectItem(withTag: Self.tag(preferences.dictation))
        doNotDisturbPopup.selectItem(withTag: Self.tag(preferences.doNotDisturb))
        mediaPopup.selectItem(withTag: Self.tag(preferences.media))
        shortcuts = preferences.shortcuts
    }

    private func draft() -> KeyboardRoutingPreferences {
        KeyboardRoutingPreferences(
            brightness: Self.route(brightnessPopup),
            missionControl: Self.route(missionControlPopup),
            spotlight: Self.route(spotlightPopup),
            dictation: Self.route(dictationPopup),
            doNotDisturb: Self.route(doNotDisturbPopup),
            media: Self.route(mediaPopup),
            shortcuts: shortcuts
        )
    }

    private static func tag(_ route: KeyRoute) -> Int { route == .omarchy ? 1 : 0 }

    private static func route(_ popup: NSPopUpButton) -> KeyRoute {
        popup.selectedItem?.tag == 1 ? .omarchy : .macOS
    }
}
