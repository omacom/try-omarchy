import AppKit

/// Permission changes update existing controls without replacing the scroll
/// view, resetting keyboard focus, or running unrelated storage probes.
@MainActor
final class StartMenuPermissionRow: NSView {
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let button: OmarchyActionButton
    private let trailing = NSStackView()
    private var presentation: StartMenuPermissionPresentation?

    init(symbolName: String, title: String, target: AnyObject) {
        button = OmarchyActionButton(title: "", style: .secondary, target: target, action: nil)
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("permission-row-\(symbolName)")
        translatesAutoresizingMaskIntoConstraints = false

        let symbol = NSImageView()
        symbol.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 19, weight: .medium)
        symbol.contentTintColor = OmarchyStartMenuTheme.accent
        symbol.identifier = NSUserInterfaceItemIdentifier("permission-symbol-\(symbolName)")
        symbol.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: title)
        name.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
        name.textColor = OmarchyStartMenuTheme.foreground
        name.identifier = NSUserInterfaceItemIdentifier("permission-title-\(symbolName)")
        detail.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        detail.textColor = OmarchyStartMenuTheme.muted
        detail.maximumNumberOfLines = 2
        detail.identifier = NSUserInterfaceItemIdentifier("permission-detail-\(symbolName)")
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let labels = NSStackView(views: [name, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        status.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        status.alignment = .right
        status.identifier = NSUserInterfaceItemIdentifier("permission-status-\(symbolName)")
        button.identifier = NSUserInterfaceItemIdentifier("permission-action-\(symbolName)")
        trailing.orientation = .vertical
        trailing.alignment = .trailing
        trailing.spacing = 7
        trailing.detachesHiddenViews = true
        trailing.translatesAutoresizingMaskIntoConstraints = false
        trailing.addArrangedSubview(status)
        trailing.addArrangedSubview(button)
        addSubview(symbol)
        addSubview(labels)
        addSubview(trailing)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 68),
            symbol.widthAnchor.constraint(equalToConstant: 26),
            symbol.heightAnchor.constraint(equalToConstant: 26),
            symbol.leadingAnchor.constraint(equalTo: leadingAnchor),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 12),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -12),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: labels.trailingAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.widthAnchor.constraint(equalToConstant: 124),
            button.widthAnchor.constraint(equalToConstant: 124),
            button.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ presentation: StartMenuPermissionPresentation, action: Selector) {
        guard self.presentation != presentation else { return }
        self.presentation = presentation
        detail.stringValue = presentation.detail
        let text = presentation.isGranted ? "●  Yes" : "○  No"
        let attributedStatus = NSMutableAttributedString(string: text, attributes: [
            .font: status.font!,
            .foregroundColor: presentation.isGranted
                ? OmarchyStartMenuTheme.foreground : OmarchyStartMenuTheme.muted,
        ])
        if presentation.isGranted {
            attributedStatus.addAttribute(.foregroundColor, value: OmarchyStartMenuTheme.success,
                                          range: NSRange(location: 0, length: 1))
        }
        status.attributedStringValue = attributedStatus
        button.updateTitle(presentation.actionTitle ?? "")
        button.action = action
        button.isHidden = presentation.actionTitle == nil
    }
}
