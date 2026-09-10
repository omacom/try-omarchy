import AppKit
import Testing
@testable import OmarchyVMHelper

@Suite("Start menu automatic startup", .serialized)
@MainActor
struct StartMenuStartupTests {
    @Test("Automatic startup uses the launch action without presenting the menu")
    func startsWithoutShowingMenu() throws {
        _ = NSApplication.shared
        var automaticStart = false
        var launchCount = 0
        let menu = makeMenu(
            storageState: { .defaultLocation },
            startAutomatically: { automaticStart },
            setStartAutomatically: { automaticStart = $0 },
            launch: { launchCount += 1 }
        )
        defer { menu.dismiss() }
        menu.prepareForPresentation(visibleFrame: nil)
        let content = try #require(menu.window.contentView)
        let checkbox = try #require(descendant(
            withIdentifier: "automatic-start-checkbox", in: content
        ) as? NSButton)
        #expect(checkbox.state == .off)
        checkbox.performClick(nil)
        #expect(automaticStart)
        #expect(launchCount == 0)

        menu.launchOmarchy()
        menu.launchOmarchy()
        #expect(launchCount == 1)
        #expect(!menu.window.isVisible)
        let launchingCheckbox = try #require(descendant(
            withIdentifier: "automatic-start-checkbox", in: content
        ) as? NSButton)
        #expect(launchingCheckbox.state == .on)
        #expect(!launchingCheckbox.isEnabled)
    }

    @Test("Running settings can change startup and close without launching or quitting the VM")
    func runningSettings() throws {
        _ = NSApplication.shared
        var automaticStart = true
        var launchCount = 0
        var closeCount = 0
        let menu = makeMenu(
            storageState: { .defaultLocation },
            startAutomatically: { automaticStart },
            setStartAutomatically: { automaticStart = $0 },
            launch: { launchCount += 1 }
        )
        defer { menu.dismiss() }
        menu.launchOmarchy()
        menu.virtualMachineDidStart { closeCount += 1 }
        menu.prepareForPresentation(visibleFrame: nil)
        let content = try #require(menu.window.contentView)
        let checkbox = try #require(descendant(
            withIdentifier: "automatic-start-checkbox", in: content
        ) as? NSButton)
        #expect(checkbox.isEnabled)
        checkbox.performClick(nil)
        #expect(!automaticStart)
        for identifier in ["permission-action-folder", "permission-action-network", "permission-action-cpu"] {
            let button = try #require(descendant(withIdentifier: identifier, in: content) as? NSButton)
            #expect(button.isEnabled)
        }
        let immersive = try #require(descendant(withIdentifier: "immersive-toggle", in: content) as? NSButton)
        #expect(immersive.isEnabled)
        for identifier in ["restart-vm-button", "manage-vm-button"] {
            #expect(try #require(descendant(withIdentifier: identifier, in: content) as? NSButton).isEnabled)
        }
        menu.shutdownDidBegin()
        for identifier in ["automatic-start-checkbox", "permission-action-folder", "permission-action-network", "permission-action-cpu", "restart-vm-button", "manage-vm-button"] {
            #expect(!(try #require(descendant(withIdentifier: identifier, in: content) as? NSButton)).isEnabled)
        }
        menu.launchOmarchy()
        #expect(launchCount == 1)
        let done = try #require(descendant(withIdentifier: "launch-button", in: content) as? NSButton)
        #expect(done.isEnabled)
        done.performClick(nil)
        #expect(closeCount == 1)
        #expect(menu.windowShouldClose(menu.window) == false)
        #expect(closeCount == 2)
        #expect(launchCount == 1)
    }

    private func makeMenu(
        storageState: @escaping () -> StorageLocationMenuState,
        startAutomatically: @escaping () -> Bool = { false },
        setStartAutomatically: @escaping (Bool) -> Void = { _ in },
        launch: @escaping () -> Void = {}
    ) -> StartMenuWindow {
        StartMenuWindow(
            accessibilityStatus: { true },
            microphoneStatus: { .authorized },
            cameraStatus: { .authorized },
            requestAccessibility: {},
            requestMicrophone: { completion in completion(true) },
            requestCamera: { completion in completion(true) },
            canResetStorage: true,
            storageLocation: { storageState().displayPath },
            storageLocationURL: {
                storageState().containerPath.map { URL(fileURLWithPath: $0) }
            },
            storageSpaceEstimate: { nil },
            storageLocationStatus: storageState,
            validateStorageLocation: { _ in nil },
            chooseStorageLocation: { _ in nil },
            useDefaultStorageLocation: {},
            resetStorage: {},
            sharedFolderStatus: { .disabled },
            chooseSharedFolder: { _ in nil },
            setSharedFolderEnabled: { _ in },
            portForwardingStatus: { [] },
            immersiveMode: { true },
            setImmersiveMode: { _ in },
            startAutomatically: startAutomatically,
            setStartAutomatically: setStartAutomatically,
            launch: launch
        )
    }

    private func descendant(withIdentifier identifier: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == identifier { return view }
        for child in view.subviews {
            if let found = descendant(withIdentifier: identifier, in: child) { return found }
        }
        return nil
    }
}
