import AppKit

/// AppKit activation and modal presentation can overlap the handoff to QEMU.
/// Keep the intended policy and check it again after the current UI operation.
@MainActor
final class ApplicationActivationController {
    private var desiredPolicy = ApplicationPresentation.prelaunchActivationPolicy
    private var reconciliationScheduled = false
    private let currentPolicy: @MainActor () -> NSApplication.ActivationPolicy
    private let setPolicy: @MainActor (NSApplication.ActivationPolicy) -> Bool
    private let schedule: (@escaping @MainActor () -> Void) -> Void

    convenience init() {
        self.init(
            currentPolicy: { NSApp.activationPolicy() },
            setPolicy: { NSApp.setActivationPolicy($0) },
            schedule: { action in
                RunLoop.main.perform(inModes: [.common, .modalPanel]) {
                    MainActor.assumeIsolated { action() }
                }
            }
        )
    }

    init(
        currentPolicy: @escaping @MainActor () -> NSApplication.ActivationPolicy,
        setPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Bool,
        schedule: @escaping (@escaping @MainActor () -> Void) -> Void
    ) {
        self.currentPolicy = currentPolicy
        self.setPolicy = setPolicy
        self.schedule = schedule
    }

    func setDesiredPolicy(_ policy: NSApplication.ActivationPolicy) {
        desiredPolicy = policy
        reconcile()
    }

    func reconcile() {
        applyPolicy()
        guard !reconciliationScheduled else { return }
        reconciliationScheduled = true
        schedule { [weak self] in
            guard let self else { return }
            self.reconciliationScheduled = false
            // Read the current intent: QEMU may have exited and returned to
            // the start menu while this check was waiting to run.
            self.applyPolicy()
        }
    }

    private func applyPolicy() {
        guard currentPolicy() != desiredPolicy else { return }
        if !setPolicy(desiredPolicy) {
            fputs("omarchy-vm-helper: AppKit rejected activation policy \(desiredPolicy.rawValue)\n", stderr)
        }
    }
}

enum ApplicationHelpLink: Int, CaseIterable {
    case usage
    case troubleshooting
    case reportIssue

    var title: String {
        switch self {
        case .usage: "Try Omarchy Help"
        case .troubleshooting: "Troubleshooting"
        case .reportIssue: "Report an Issue…"
        }
    }

    var url: URL {
        switch self {
        case .usage: URL(string: "https://github.com/omacom/try-omarchy/blob/main/README.md")!
        case .troubleshooting: URL(string: "https://github.com/omacom/try-omarchy/blob/main/README.md#data-and-updates")!
        case .reportIssue: URL(string: "https://github.com/omacom/try-omarchy/issues")!
        }
    }
}

@MainActor
enum ApplicationPresentation {
    static let prelaunchActivationPolicy = NSApplication.ActivationPolicy.regular
    static let runningActivationPolicy = NSApplication.ActivationPolicy.accessory

    static func installMainMenu(
        in application: NSApplication,
        applicationName: String,
        actionsTarget: AnyObject? = nil
    ) {
        let mainMenu = NSMenu(title: "Main Menu")

        let applicationItem = NSMenuItem()
        mainMenu.addItem(applicationItem)
        let applicationMenu = NSMenu(title: applicationName)
        applicationItem.submenu = applicationMenu
        applicationMenu.addItem(
            withTitle: "About \(applicationName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: "Settings…",
            action: #selector(VMApplicationController.showSettings(_:)),
            keyEquivalent: ","
        ).target = actionsTarget
        applicationMenu.addItem(
            withTitle: "Check for Updates…",
            action: #selector(VMApplicationController.checkForAppUpdates(_:)),
            keyEquivalent: ""
        ).target = actionsTarget
        applicationMenu.addItem(.separator())
        let servicesItem = applicationMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: "Hide \(applicationName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        applicationMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        ).keyEquivalentModifierMask = [.command, .option]
        applicationMenu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: "Quit \(applicationName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        // A nil target routes these shortcuts to the focused text control.
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(
            withTitle: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        windowMenu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )

        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        helpItem.submenu = helpMenu
        for link in ApplicationHelpLink.allCases {
            let item = helpMenu.addItem(
                withTitle: link == .usage ? "\(applicationName) Help" : link.title,
                action: #selector(VMApplicationController.openHelpLink(_:)),
                keyEquivalent: link == .usage ? "?" : ""
            )
            item.tag = link.rawValue
            item.target = actionsTarget
        }

        application.mainMenu = mainMenu
        application.servicesMenu = servicesMenu
        application.windowsMenu = windowMenu
        application.helpMenu = helpMenu
    }
}
