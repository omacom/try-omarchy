import AppKit

@MainActor
enum GuestBootFixPrompt {
    static func review() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Update your VM"
        alert.informativeText = "Add Mac integrations and apply compatible fixes before Omarchy starts."
        alert.accessoryView = updateSummary()
        alert.addButton(withTitle: "Update and Launch")
        alert.addButton(withTitle: "Skip and Launch")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        return alert
    }

    private static func updateSummary() -> NSView {
        let features = [
            [("battery.100", "Battery widget"), ("touchid", "Touch ID support"),
             ("key", "Existing 1Password support"), ("slider.horizontal.3", "Integration setup"),
             ("lock", "Lock-screen support")],
            [("doc.on.clipboard", "Clipboard & screensaver"), ("hand.draw", "Pinch zoom & app menus"),
             ("terminal", "Alacritty rendering"), ("arrow.down.app", "Ghostty installer"),
             ("gearshape", "Power, clock & update fixes")],
        ]
        let columns = features.map { entries in
            let rows = entries.map { symbol, title in
                let icon = NSImageView()
                icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
                icon.contentTintColor = .secondaryLabelColor
                icon.translatesAutoresizingMaskIntoConstraints = false
                icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
                icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
                let label = NSTextField(labelWithString: title)
                label.font = .systemFont(ofSize: 12)
                let row = NSStackView(views: [icon, label])
                row.alignment = .centerY
                row.spacing = 8
                return row
            }
            let column = NSStackView(views: rows)
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 10
            return column
        }
        let list = NSStackView(views: columns)
        list.alignment = .top
        list.distribution = .fillEqually
        list.spacing = 20

        let divider = NSBox()
        divider.boxType = .separator
        let preservation = NSTextField(wrappingLabelWithString:
            "Your files, settings, customizations, and kernel are kept. Unsupported fixes are skipped; failed changes are restored.")
        preservation.font = .systemFont(ofSize: 12)
        let requirements = NSTextField(wrappingLabelWithString:
            "Touch ID stays optional. Battery support requires matching headers and build tools already in the VM.")
        requirements.font = .systemFont(ofSize: 11)
        requirements.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [list, divider, preservation, requirements])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 440).isActive = true
        for view in [list, divider, preservation, requirements] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.layoutSubtreeIfNeeded()
        stack.setFrameSize(stack.fittingSize)
        return stack
    }

    static func result(_ result: GuestBootFixResult) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = result.isWarning ? .warning : .informational
        alert.messageText = result.title
        alert.informativeText = result.message
        alert.addButton(withTitle: "OK")
        return alert
    }

    static func skip() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Launch without updating?"
        alert.informativeText = "These fixes won’t be applied. You can update on a later launch. Any interrupted update will still recover its original files."
        alert.addButton(withTitle: "Go Back")
        alert.addButton(withTitle: "Skip and Launch")
        return alert
    }
}
