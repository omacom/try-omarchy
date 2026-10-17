import AppKit

/// Shared System Settings–style building blocks for the configuration sheets:
/// an icon tile header, grouped form containers, rows, footnotes and buttons.
/// Everything resolves through semantic system colors so sheets follow the
/// Mac's light or dark appearance.
@MainActor
enum NativeSheetChrome {
    static let margin: CGFloat = 20
    static let rowInset: CGFloat = 10

    static func window(title: String, width: CGFloat) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setAccessibilityLabel(title)
        return window
    }

    /// Pins `stack` inside a fresh content view at a fixed width and sizes the
    /// window to fit the stack's height.
    static func install(_ stack: NSStackView, in window: NSWindow, width: CGFloat) {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: width),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: margin),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin),
        ])
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: width, height: content.fittingSize.height))
    }

    static func header(symbol: String, color: NSColor, title: String, subtitle: NSTextField) -> NSView {
        let tile = SettingsIconTile(symbol: symbol, color: color)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .labelColor
        subtitle.font = .preferredFont(forTextStyle: .subheadline)
        subtitle.textColor = .secondaryLabelColor
        let text = NSStackView(views: [titleLabel, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        subtitle.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        let row = NSStackView(views: [tile, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }

    static func header(symbol: String, color: NSColor, title: String, subtitle: String) -> NSView {
        header(symbol: symbol, color: color, title: title,
               subtitle: NSTextField(wrappingLabelWithString: subtitle))
    }

    /// A section title shown above a group, like grouped `Form` section headers.
    static func sectionTitle(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.textColor = .labelColor
        return inset(label)
    }

    /// Stacks rows in a rounded group with hairline separators between them.
    static func group(_ rows: [NSView]) -> FormGroupView {
        let group = FormGroupView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let line = separator()
                stack.addArrangedSubview(line)
                NSLayoutConstraint.activate([
                    line.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: rowInset),
                    line.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -rowInset),
                ])
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        group.embed(stack)
        return group
    }

    /// A form row: title with optional secondary detail below, control trailing.
    static func row(title: NSTextField, detail: NSTextField? = nil, control: NSView? = nil) -> NSView {
        title.font = .systemFont(ofSize: NSFont.systemFontSize)
        title.textColor = .labelColor
        var labels: [NSView] = [title]
        if let detail {
            detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            detail.textColor = .secondaryLabelColor
            labels.append(detail)
        }
        let text = NSStackView(views: labels)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        for label in labels {
            label.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        }
        let row = NSView()
        row.addSubview(text)
        var constraints = [
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            text.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: rowInset),
            text.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            text.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 9),
        ]
        if let control {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.addSubview(control)
            constraints += [
                text.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -16),
                control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -rowInset),
                control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                control.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 6),
            ]
            let fill = text.trailingAnchor.constraint(equalTo: control.leadingAnchor, constant: -16)
            fill.priority = .defaultLow
            constraints.append(fill)
        } else {
            constraints.append(text.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -rowInset))
        }
        NSLayoutConstraint.activate(constraints)
        return row
    }

    static func row(title: String, detail: String? = nil, control: NSView? = nil) -> NSView {
        row(title: NSTextField(wrappingLabelWithString: title),
            detail: detail.map { NSTextField(wrappingLabelWithString: $0) },
            control: control)
    }

    /// Small secondary text under a group, aligned with the group's content.
    static func footnote(_ field: NSTextField) -> NSView {
        styleFootnote(field)
        return inset(field)
    }

    static func footnote(_ text: String) -> NSView {
        footnote(NSTextField(wrappingLabelWithString: text))
    }

    static func styleFootnote(_ field: NSTextField) {
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
    }

    /// Wraps a view so its edges sit `rowInset` in from the container's edges,
    /// lining it up with the text inside groups.
    static func inset(_ view: NSView) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: rowInset),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -rowInset),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    static func button(_ title: String, target: AnyObject?, action: Selector?) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .push
        button.controlSize = .regular
        return button
    }

    static func destructiveButton(_ title: String, target: AnyObject?, action: Selector?) -> NSButton {
        let button = DestructivePushButton(title: title, target: target, action: action)
        button.bezelStyle = .push
        button.controlSize = .regular
        return button
    }

    /// Buttons in macOS order: `leading` at the left, then a flexible gap,
    /// then `trailing` ending with the default button.
    static func actions(leading: [NSView] = [], trailing: [NSView]) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: leading + [spacer] + trailing)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    static func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    /// The tile as an image, for NSAlert's icon slot.
    static func iconImage(symbol: String, color: NSColor, size: CGFloat = 64) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let path = NSBezierPath(
                roundedRect: rect,
                xRadius: rect.width * SettingsIconTile.cornerFraction,
                yRadius: rect.height * SettingsIconTile.cornerFraction
            )
            let (top, bottom) = SettingsIconTile.gradientColors(color)
            NSGradient(starting: top, ending: bottom)?.draw(in: path, angle: -90)
            let configuration = NSImage.SymbolConfiguration(
                pointSize: rect.height * SettingsIconTile.symbolFraction, weight: .medium
            ).applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) {
                let glyphSize = glyph.size
                glyph.draw(in: NSRect(
                    x: rect.midX - glyphSize.width / 2,
                    y: rect.midY - glyphSize.height / 2,
                    width: glyphSize.width,
                    height: glyphSize.height
                ))
            }
            return true
        }
        return image
    }
}

/// A push button with a red title for actions that discard data.
final class DestructivePushButton: NSButton {
    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        bezelStyle = .push
        hasDestructiveAction = true
        refreshTitle()
    }

    override var isEnabled: Bool {
        didSet { refreshTitle() }
    }

    private func refreshTitle() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: isEnabled ? NSColor.systemRed : NSColor.disabledControlTextColor,
            .paragraphStyle: paragraph,
        ])
    }
}

/// A System Settings–style icon: a continuous rounded square filled with a
/// gradient of `color`, carrying a white SF Symbol.
final class SettingsIconTile: NSView {
    static let cornerFraction: CGFloat = 0.23
    static let symbolFraction: CGFloat = 0.5

    private let color: NSColor
    private let gradient = CAGradientLayer()
    private let glyph = NSImageView()

    init(symbol: String, color: NSColor, size: CGFloat = 34) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
        gradient.cornerRadius = size * Self.cornerFraction
        gradient.cornerCurve = .continuous
        gradient.masksToBounds = true
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(gradient)
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: size * Self.symbolFraction, weight: .medium
        )
        glyph.contentTintColor = .white
        glyph.imageScaling = .scaleProportionallyDown
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.72),
            glyph.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, multiplier: 0.72),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    static func gradientColors(_ color: NSColor) -> (NSColor, NSColor) {
        let top = color.blended(withFraction: 0.22, of: .white) ?? color
        let bottom = color.blended(withFraction: 0.08, of: .black) ?? color
        return (top, bottom)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        gradient.frame = bounds
        let (top, bottom) = Self.gradientColors(color)
        gradient.colors = [top.cgColor, bottom.cgColor]
    }

    override func layout() {
        super.layout()
        gradient.frame = bounds
    }
}

/// The rounded, softly filled container behind a group of form rows.
final class FormGroupView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    func embed(_ content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        layer?.borderWidth = 1 / max(window?.backingScaleFactor ?? 2, 1)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }
}
