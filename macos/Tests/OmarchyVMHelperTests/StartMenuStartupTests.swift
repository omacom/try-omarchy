import AppKit
import Testing
@testable import OmarchyVMHelper

@Suite("Start menu automatic startup", .serialized)
@MainActor
struct StartMenuStartupTests {
    @Test("Enabling automatic startup requires confirmation before saving",
          arguments: [true, false])
    func confirmsAutomaticStartup(confirmed: Bool) throws {
        _ = NSApplication.shared
        var automaticStart = false
        var launchCount = 0
        var confirmationCount = 0
        let menu = makeMenu(
            storageState: { .defaultLocation },
            startAutomatically: { automaticStart },
            setStartAutomatically: { automaticStart = $0 },
            confirmAutomaticStartup: { alert in
                confirmationCount += 1
                #expect(!automaticStart)
                #expect(launchCount == 0)
                #expect(alert.messageText == "Skip the launcher")
                #expect(alert.informativeText.contains("hold Option while opening the app"))
                #expect(alert.informativeText.contains("Setup → Try Omarchy Settings"))
                #expect(alert.buttons.map(\.title) == ["OK", "Cancel"])
                return confirmed ? .alertFirstButtonReturn : .alertSecondButtonReturn
            },
            launch: { launchCount += 1 }
        )
        defer { menu.dismiss() }
        menu.prepareForPresentation(visibleFrame: nil)
        let content = try #require(menu.window.contentView)
        let toggle = try #require(descendant(
            withIdentifier: "automatic-start-toggle", in: content
        ) as? NSButton)
        #expect(toggle.state == .off)
        toggle.performClick(nil)
        #expect(automaticStart == confirmed)
        #expect(toggle.state == (confirmed ? .on : .off))
        #expect(confirmationCount == 1)
        #expect(launchCount == 0)

        menu.launchOmarchy()
        menu.launchOmarchy()
        #expect(launchCount == 1)
        #expect(!menu.window.isVisible)
        let launchingToggle = try #require(descendant(
            withIdentifier: "automatic-start-toggle", in: content
        ) as? NSButton)
        #expect(launchingToggle.state == (confirmed ? .on : .off))
        #expect(!launchingToggle.isEnabled)
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
            confirmAutomaticStartup: { _ in
                Issue.record("Disabling automatic startup must not ask for confirmation")
                return .alertSecondButtonReturn
            },
            launch: { launchCount += 1 }
        )
        defer { menu.dismiss() }
        menu.launchOmarchy()
        menu.virtualMachineDidStart { closeCount += 1 }
        menu.prepareForPresentation(visibleFrame: nil)
        let content = try #require(menu.window.contentView)
        let toggle = try #require(descendant(
            withIdentifier: "automatic-start-toggle", in: content
        ) as? NSButton)
        #expect(toggle.isEnabled)
        toggle.performClick(nil)
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
        for identifier in ["automatic-start-toggle", "permission-action-folder", "permission-action-network", "permission-action-cpu", "restart-vm-button", "manage-vm-button"] {
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

    @Test("Failed fixes leave ordinary launch available and require a separate manual retry")
    func failedFixesStayManual() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("boot-fixes-123.json")
        let identity = String(repeating: "a", count: 64)
        try GuestBootFixCache.retain(GuestBootFixReport(schema: 1, type: "boot-fixes", identity: identity,
            state: "failed", components: GuestBootFixReport.pendingComponents), cacheURL: url)
        var launchCount = 0
        var retryCount = 0
        let menu = makeMenu(storageState: { .defaultLocation }, startAutomatically: { true },
                            bootFixCacheURL: { url }, bootFixIdentity: { identity },
                            retryBootFixes: { retryCount += 1 }, launch: { launchCount += 1 })
        defer { menu.dismiss() }
        menu.prepareForPresentation(visibleFrame: nil)
        let content = try #require(menu.window.contentView)
        let launch = try #require(descendant(withIdentifier: "launch-button", in: content) as? NSButton)
        #expect(launch.accessibilityLabel() == "Launch Omarchy")
        launch.performClick(nil)
        #expect(launchCount == 1)
        #expect(retryCount == 0)
        let retryMenu = makeMenu(storageState: { .defaultLocation }, startAutomatically: { true },
                                bootFixCacheURL: { url }, bootFixIdentity: { identity },
                                retryBootFixes: { retryCount += 1 }, launch: { launchCount += 1 })
        defer { retryMenu.dismiss() }
        retryMenu.prepareForPresentation(visibleFrame: nil)
        let retryContent = try #require(retryMenu.window.contentView)
        let retry = try #require(descendant(withIdentifier: "review-boot-fixes-button", in: retryContent) as? NSButton)
        #expect(retry.isEnabled)
        retry.performClick(nil)
        #expect(retryCount == 1)
        #expect(launchCount == 1)
        retryMenu.virtualMachineDidStart {}
        retryMenu.prepareForPresentation(visibleFrame: nil)
        let runningRetry = try #require(descendant(withIdentifier: "review-boot-fixes-button", in: retryContent) as? NSButton)
        #expect(!runningRetry.isEnabled)
        #expect(runningRetry.toolTip?.contains("Shut down") == true)
    }

    private func makeMenu(
        storageState: @escaping () -> StorageLocationMenuState,
        startAutomatically: @escaping () -> Bool = { false },
        setStartAutomatically: @escaping (Bool) -> Void = { _ in },
        confirmAutomaticStartup: @escaping (NSAlert) -> NSApplication.ModalResponse = { _ in .alertFirstButtonReturn },
        bootFixCacheURL: @escaping () -> URL? = { nil },
        bootFixIdentity: @escaping () -> String? = { nil },
        retryBootFixes: @escaping () -> Void = {},
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
            confirmAutomaticStartup: confirmAutomaticStartup,
            bootFixCacheURL: bootFixCacheURL,
            bootFixIdentity: bootFixIdentity,
            retryBootFixes: retryBootFixes,
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
