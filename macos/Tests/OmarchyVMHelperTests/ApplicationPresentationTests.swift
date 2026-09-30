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
        defer {
            application.mainMenu = previousMainMenu
            application.windowsMenu = previousWindowMenu
        }

        let updatesTarget = NSObject()
        ApplicationPresentation.installMainMenu(
            in: application,
            applicationName: "Try Omarchy",
            updatesTarget: updatesTarget
        )

        let appMenu = try #require(application.mainMenu?.items.first?.submenu)
        let quit = try #require(appMenu.items.first(where: {
            $0.title == "Quit Try Omarchy"
        }))
        #expect(quit.keyEquivalent == "q")
        #expect(quit.action == #selector(NSApplication.terminate(_:)))

        let updates = try #require(appMenu.items.first(where: { $0.title == "Check for Updates…" }))
        #expect(updates.action == #selector(VMApplicationController.checkForAppUpdates(_:)))
        #expect(updates.target === updatesTarget)

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
    }
}
