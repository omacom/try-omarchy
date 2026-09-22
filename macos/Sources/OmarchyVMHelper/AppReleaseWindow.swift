import AppKit

@MainActor
final class AppReleaseWindow: NSObject {
    private let checker: AppReleaseChecker
    private let window: NSWindow
    private let status = NSTextField(wrappingLabelWithString: "")
    private let checkButton = NSButton(title: "Check Now", target: nil, action: nil)
    private let automatic = NSButton(checkboxWithTitle: "Automatically check for updates", target: nil, action: nil)

    init(checker: AppReleaseChecker) {
        self.checker = checker
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        super.init()
        window.title = "Try Omarchy Updates"
        window.isReleasedWhenClosed = false

        let installed = NSTextField(wrappingLabelWithString: checker.installed.label)
        installed.font = .systemFont(ofSize: 16, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString: "Updates are downloaded from GitHub and installed manually. Shut down Omarchy before replacing the Mac app. Your existing VM and settings are preserved; the guest is updated separately.")
        explanation.textColor = .secondaryLabelColor
        let privacy = NSTextField(wrappingLabelWithString: "When enabled, checks contact GitHub at most once a day when you open the app. App updates aren’t downloaded or installed automatically.")
        privacy.textColor = .secondaryLabelColor
        privacy.font = .systemFont(ofSize: 11)
        let releases = NSButton(title: "Release Notes & Download…", target: self, action: #selector(openRelease))
        releases.bezelStyle = .rounded
        checkButton.bezelStyle = .rounded
        checkButton.target = self
        checkButton.action = #selector(checkNow)
        automatic.target = self
        automatic.action = #selector(toggleAutomatic)
        let actions = NSStackView(views: [checkButton, releases])
        actions.spacing = 12
        let stack = NSStackView(views: [installed, status, actions, automatic, privacy, explanation])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            installed.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            privacy.widthAnchor.constraint(equalTo: stack.widthAnchor),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        refresh()
    }

    func show() {
        refresh()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        checker.check()
    }

    func refresh() {
        status.stringValue = checker.state.message
        checkButton.isEnabled = checker.state != .checking
        automatic.state = checker.preferences.automaticChecks ? .on : .off
    }

    @objc private func checkNow() { checker.check() }

    @objc private func toggleAutomatic() {
        checker.preferences.automaticChecks = automatic.state == .on
        checker.checkAutomaticallyIfDue()
    }

    @objc private func openRelease() { NSWorkspace.shared.open(checker.state.releaseURL) }
}
