import AppKit

@MainActor
enum ApplicationPresentation {
    static let prelaunchActivationPolicy = NSApplication.ActivationPolicy.regular
    static let runningActivationPolicy = NSApplication.ActivationPolicy.accessory

    static func installMainMenu(
        in application: NSApplication,
        applicationName: String,
        updatesTarget: AnyObject? = nil
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
        applicationMenu.addItem(
            withTitle: "Check for Updates…",
            action: #selector(VMApplicationController.checkForAppUpdates(_:)),
            keyEquivalent: ""
        ).target = updatesTarget
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: "Hide \(applicationName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
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

        application.mainMenu = mainMenu
        application.windowsMenu = windowMenu
    }
}
