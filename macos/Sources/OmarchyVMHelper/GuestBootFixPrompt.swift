import AppKit

@MainActor
enum GuestBootFixPrompt {
    static func review(catalog: GuestBootFixCatalog) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Update your VM"
        alert.informativeText = "Add Mac integrations and apply compatible fixes before Omarchy starts."
        alert.accessoryView = updateSummary(catalog)
        alert.addButton(withTitle: "Update and Launch")
        alert.addButton(withTitle: "Skip and Launch")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        return alert
    }

    private static func updateSummary(_ catalog: GuestBootFixCatalog) -> NSView {
        let features = catalog.features
        let midpoint = (features.count + 1) / 2
        let columns = [features.prefix(midpoint), features.dropFirst(midpoint)].filter { !$0.isEmpty }.map { entries in
            let rows = entries.map { feature in
                let icon = NSImageView()
                icon.image = NSImage(systemSymbolName: feature.icon, accessibilityDescription: nil)
                icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
                icon.contentTintColor = .secondaryLabelColor
                icon.translatesAutoresizingMaskIntoConstraints = false
                icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
                icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
                let label = NSTextField(wrappingLabelWithString: feature.title)
                label.font = .systemFont(ofSize: 12)
                label.widthAnchor.constraint(equalToConstant: 184).isActive = true
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
        let requirements = NSTextField(wrappingLabelWithString: catalog.notes)
        requirements.font = .systemFont(ofSize: 11)
        requirements.textColor = .secondaryLabelColor

        let views: [NSView] = [list, divider, preservation] + (catalog.notes.isEmpty ? [] : [requirements])
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 440).isActive = true
        for view in views {
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
