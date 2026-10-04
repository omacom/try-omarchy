import AppKit
import Testing
@testable import OmarchyVMHelper

@Suite("Start menu automatic startup", .serialized)
@MainActor
struct StartMenuStartupTests {
    @Test("The first launcher offers Update before the guest has reported anything")
    func firstLaunchOffersUpdate() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("boot-fixes-123.json")
        let identity = String(repeating: "a", count: 64)
        let menu = makeMenu(storageState: { .defaultLocation }, startAutomatically: { true },
                            bootFixCacheURL: { url }, bootFixIdentity: { identity })
        defer { menu.dismiss() }
        menu.prepareForPresentation(visibleFrame: nil)
        let content = try #require(menu.window.contentView)
        let launch = try #require(descendant(withIdentifier: "launch-button", in: content) as? NSButton)
        #expect(launch.accessibilityLabel() == "Update and Launch")
        #expect(launch.isEnabled)
        #expect(descendant(withIdentifier: "review-boot-fixes-button", in: content) == nil)
        try GuestBootFixCache.recordReview(cacheURL: url, identity: identity)
        menu.refreshBootFixStatus()
        let reviewedContent = try #require(menu.window.contentView)
        #expect(try #require(descendant(withIdentifier: "launch-button", in: reviewedContent) as? NSButton).accessibilityLabel() == "Update and Launch")
        #expect(descendant(withIdentifier: "review-boot-fixes-button", in: reviewedContent) == nil)
    }

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
            setStartAutomatically: { automaticStart = $0; return nil },
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

    @Test("A failed startup preference write restores the toggle and explains the error",
          arguments: [false, true])
    func failedStartupSave(wasEnabled: Bool) throws {
        _ = NSApplication.shared
        var attempts = 0
        var errorsPresented = 0
        let menu = makeMenu(
            storageState: { .defaultLocation },
            startAutomatically: { wasEnabled },
            setStartAutomatically: { enabled in
                attempts += 1
                #expect(enabled == !wasEnabled)
                return "The workspace is read-only."
            },
            presentStartupSaveError: { alert, _ in
                errorsPresented += 1
                #expect(alert.messageText == "Skip launcher couldn’t be saved")
                #expect(alert.informativeText == "The workspace is read-only.")
            }
        )
        defer { menu.dismiss() }
        menu.prepareForPresentation(visibleFrame: nil)
        let content = try #require(menu.window.contentView)
        let toggle = try #require(descendant(
            withIdentifier: "automatic-start-toggle", in: content
        ) as? NSButton)
        toggle.performClick(nil)
        #expect(attempts == 1)
        #expect(toggle.state == (wasEnabled ? .on : .off))
        #expect(errorsPresented == 1)
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
            setStartAutomatically: { automaticStart = $0; return nil },
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

    @Test("Failed fixes use the main Update action for a manual retry")
    func failedFixesUseUpdate() throws {
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
        #expect(launch.accessibilityLabel() == "Update and Launch")
        #expect(descendant(withIdentifier: "review-boot-fixes-button", in: content) == nil)
        launch.performClick(nil)
        #expect(launchCount == 0)
        #expect(retryCount == 1)
        let retryMenu = makeMenu(storageState: { .defaultLocation }, startAutomatically: { true },
                                bootFixCacheURL: { url }, bootFixIdentity: { identity },
                                retryBootFixes: { retryCount += 1 }, launch: { launchCount += 1 })
        defer { retryMenu.dismiss() }
        retryMenu.prepareForPresentation(visibleFrame: nil)
        let retryContent = try #require(retryMenu.window.contentView)
        let retry = try #require(descendant(withIdentifier: "launch-button", in: retryContent) as? NSButton)
        #expect(retry.isEnabled)
        retry.performClick(nil)
        #expect(retryCount == 2)
        #expect(launchCount == 0)
        retryMenu.virtualMachineDidStart {}
        retryMenu.prepareForPresentation(visibleFrame: nil)
        let runningContent = try #require(retryMenu.window.contentView)
        let done = try #require(descendant(withIdentifier: "launch-button", in: runningContent) as? NSButton)
        #expect(done.accessibilityLabel() == "Done")
        #expect(descendant(withIdentifier: "review-boot-fixes-button", in: runningContent) == nil)
    }

    @Test("Fix results never add a persistent report to the launcher",
          arguments: ["checking", "running", "complete", "skipped", "failed", "recovery-required", "unconfirmed"])
    func fixResultsStayOutOfLauncher(state: String) throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("boot-fixes-123.json")
        let identity = String(repeating: "a", count: 64)
        let components = Dictionary(uniqueKeysWithValues: GuestBootFixReport.componentNames.map {
            ($0, state == "complete" ? "current" : "pending")
        })
        let report = GuestBootFixReport(schema: 1, type: "boot-fixes", identity: identity,
                                       state: state, components: components)
        try GuestBootFixCache.retain(report, cacheURL: url)
        let menu = makeMenu(storageState: { .defaultLocation }, bootFixCacheURL: { url },
                            bootFixIdentity: { identity })
        defer { menu.dismiss() }
        for running in [false, true] {
            if running { menu.virtualMachineDidStart {} }
            menu.prepareForPresentation(visibleFrame: nil)
            let content = try #require(menu.window.contentView)
            let launch = try #require(descendant(withIdentifier: "launch-button", in: content) as? NSButton)
            #expect(launch.accessibilityLabel() == (running ? "Done" : state == "complete" ? "Launch Omarchy" : "Update and Launch"))
            #expect(descendant(withIdentifier: "boot-fixes-result", in: content) == nil)
            #expect(!textFields(in: content).contains { $0.stringValue.contains(report.summary) })
            #expect(!textFields(in: content).contains { $0.stringValue.contains(report.detail) })
        }
    }

    private func makeMenu(
        storageState: @escaping () -> StorageLocationMenuState,
        startAutomatically: @escaping () -> Bool = { false },
        setStartAutomatically: @escaping (Bool) -> String? = { _ in nil },
        presentStartupSaveError: @escaping (NSAlert, NSWindow) -> Void = { _, _ in },
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
            presentStartupSaveError: presentStartupSaveError,
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

    private func textFields(in view: NSView) -> [NSTextField] {
        let fields = (view as? NSTextField).map { [$0] } ?? []
        return fields + view.subviews.flatMap { textFields(in: $0) }
    }
}
