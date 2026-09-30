import AppKit
import Testing
@testable import OmarchyVMHelper

@Suite("Application presentation", .serialized)
@MainActor
struct ApplicationPresentationTests {
    @Test("the start menu behaves like a regular app before yielding to QEMU")
    func activationPolicies() {
        #expect(ApplicationPresentation.prelaunchActivationPolicy == .regular)
        #expect(ApplicationPresentation.runningActivationPolicy == .accessory)
    }

    @Test("the application menu exposes standard application, text editing, and window shortcuts")
    func standardApplicationMenu() throws {
        let application = NSApplication.shared
        let previousMainMenu = application.mainMenu
        let previousWindowMenu = application.windowsMenu
        let previousServicesMenu = application.servicesMenu
        let previousHelpMenu = application.helpMenu
        defer {
            application.mainMenu = previousMainMenu
            application.windowsMenu = previousWindowMenu
            application.servicesMenu = previousServicesMenu
            application.helpMenu = previousHelpMenu
        }

        let actionsTarget = NSObject()
        ApplicationPresentation.installMainMenu(
            in: application,
            applicationName: "Try Omarchy",
            actionsTarget: actionsTarget
        )

        let appMenu = try #require(application.mainMenu?.items.first?.submenu)
        let quit = try #require(appMenu.items.first(where: {
            $0.title == "Quit Try Omarchy"
        }))
        #expect(quit.keyEquivalent == "q")
        #expect(quit.action == #selector(NSApplication.terminate(_:)))

        let updates = try #require(appMenu.items.first(where: { $0.title == "Check for Updates…" }))
        #expect(updates.action == #selector(VMApplicationController.checkForAppUpdates(_:)))
        #expect(updates.target === actionsTarget)

        let settings = try #require(appMenu.items.first(where: { $0.title == "Settings…" }))
        #expect(settings.action == #selector(VMApplicationController.showSettings(_:)))
        #expect(settings.target === actionsTarget)
        #expect(settings.keyEquivalent == ",")
        #expect(settings.keyEquivalentModifierMask == [.command])

        let hideOthers = try #require(appMenu.items.first(where: { $0.title == "Hide Others" }))
        #expect(hideOthers.action == #selector(NSApplication.hideOtherApplications(_:)))
        #expect(hideOthers.keyEquivalent == "h")
        #expect(hideOthers.keyEquivalentModifierMask == [.command, .option])
        #expect(hideOthers.target == nil)
        let showAll = try #require(appMenu.items.first(where: { $0.title == "Show All" }))
        #expect(showAll.action == #selector(NSApplication.unhideAllApplications(_:)))
        #expect(showAll.target == nil)

        let services = try #require(appMenu.items.first(where: { $0.title == "Services" })?.submenu)
        #expect(services === application.servicesMenu)

        let editMenu = try #require(application.mainMenu?.items.compactMap(\.submenu).first(where: {
            $0.title == "Edit"
        }))
        let editingCommands: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Undo", Selector(("undo:")), "z", [.command]),
            ("Redo", Selector(("redo:")), "z", [.command, .shift]),
            ("Cut", #selector(NSText.cut(_:)), "x", [.command]),
            ("Copy", #selector(NSText.copy(_:)), "c", [.command]),
            ("Paste", #selector(NSText.paste(_:)), "v", [.command]),
            ("Select All", #selector(NSText.selectAll(_:)), "a", [.command]),
        ]
        for (title, action, shortcut, modifiers) in editingCommands {
            let item = try #require(editMenu.items.first(where: { $0.title == title }))
            #expect(item.action == action)
            #expect(item.keyEquivalent == shortcut)
            #expect(item.keyEquivalentModifierMask == modifiers)
            #expect(item.target == nil)
        }

        let windowMenu = try #require(application.windowsMenu)
        let close = try #require(windowMenu.items.first(where: {
            $0.title == "Close Window"
        }))
        #expect(close.keyEquivalent == "w")
        #expect(close.action == #selector(NSWindow.performClose(_:)))
        let bringAllToFront = try #require(windowMenu.items.first(where: { $0.title == "Bring All to Front" }))
        #expect(bringAllToFront.action == #selector(NSApplication.arrangeInFront(_:)))
        #expect(bringAllToFront.target == nil)

        let helpMenu = try #require(application.helpMenu)
        #expect(application.mainMenu?.items.last?.submenu === helpMenu)
        #expect(helpMenu.items.map(\.title) == ["Try Omarchy Help", "Troubleshooting", "Report an Issue…"])
        for link in ApplicationHelpLink.allCases {
            let item = try #require(helpMenu.items.first(where: { $0.tag == link.rawValue }))
            #expect(item.action == #selector(VMApplicationController.openHelpLink(_:)))
            #expect(item.target === actionsTarget)
            #expect(item.keyEquivalent == (link == .usage ? "?" : ""))
        }
    }
}
