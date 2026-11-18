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
        let width: CGFloat = 540
        window = NativeSheetChrome.window(title: "Keyboard", width: width)
        window.delegate = self

        let heading = NativeSheetChrome.header(
            symbol: "keyboard", color: .systemGray, title: "Keyboard",
            subtitle: "Choose which side gets the Mac's dedicated keys while Omarchy is focused. Changes apply on the next launch."
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

        let defaults = button("Use Defaults", action: #selector(useDefaults), identifier: "defaults")
        let cancel = button("Cancel", action: #selector(cancel), identifier: "cancel")
        cancel.keyEquivalent = "\u{1b}"
        let save = button("Save", action: #selector(save), identifier: "save")
        save.keyEquivalent = "\r"
        let actions = NativeSheetChrome.actions(leading: [defaults], trailing: [cancel, save])

        let stack = NSStackView(views: [heading, group, note, actions])
        stack.spacing = 8
        stack.setCustomSpacing(16, after: heading)
        stack.setCustomSpacing(6, after: group)
        stack.setCustomSpacing(12, after: note)
        NativeSheetChrome.install(stack, in: window, width: width)
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

    @objc private func useDefaults() { setFields(.defaults) }

    private func setFields(_ preferences: KeyboardRoutingPreferences) {
        brightnessPopup.selectItem(withTag: Self.tag(preferences.brightness))
        missionControlPopup.selectItem(withTag: Self.tag(preferences.missionControl))
        spotlightPopup.selectItem(withTag: Self.tag(preferences.spotlight))
        dictationPopup.selectItem(withTag: Self.tag(preferences.dictation))
        doNotDisturbPopup.selectItem(withTag: Self.tag(preferences.doNotDisturb))
        mediaPopup.selectItem(withTag: Self.tag(preferences.media))
    }

    private func draft() -> KeyboardRoutingPreferences {
        KeyboardRoutingPreferences(
            brightness: Self.route(brightnessPopup),
            missionControl: Self.route(missionControlPopup),
            spotlight: Self.route(spotlightPopup),
            dictation: Self.route(dictationPopup),
            doNotDisturb: Self.route(doNotDisturbPopup),
            media: Self.route(mediaPopup)
        )
    }

    private static func tag(_ route: KeyRoute) -> Int { route == .omarchy ? 1 : 0 }

    private static func route(_ popup: NSPopUpButton) -> KeyRoute {
        popup.selectedItem?.tag == 1 ? .omarchy : .macOS
    }
}
