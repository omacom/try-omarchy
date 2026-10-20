import AppKit
import SwiftUI
import Testing
@testable import OmarchyVMHelper

/// Every test that builds a whole `StartMenuWindow` belongs in this one
/// serialized suite so two launchers never share the main actor at once.
@Suite("Start menu launcher", .serialized)
@MainActor
struct StartMenuLauncherTests {
    @Test("the launcher is a native window that follows the system appearance")
    func nativeWindow() throws {
        _ = NSApplication.shared
        let menu = makeMenu()
        defer { menu.dismiss() }
        #expect(menu.window.appearance == nil)
        #expect(menu.window.styleMask.contains(.resizable))
        #expect(menu.window.contentMinSize == StartMenuWindowChrome.minimumContentSize)
        #expect(menu.window.contentViewController is NSHostingController<LauncherView>)
        #expect(!menu.window.isReleasedWhenClosed)
        #expect(menu.state.selectedPane == .home)
    }

    @Test("Launch always starts Omarchy and becomes Done while it runs")
    func launchButton() {
        _ = NSApplication.shared
        var launchCount = 0
        var closeCount = 0
        let menu = makeMenu(launch: { launchCount += 1 })
        defer { menu.dismiss() }
        menu.prepareForPresentation(visibleFrame: nil)
        #expect(menu.state.launchTitle == "Launch Omarchy")
        #expect(menu.state.launchEnabled)
        menu.actions.launchOrDone()
        menu.actions.launchOrDone()
        #expect(launchCount == 1)
        #expect(!menu.state.launchEnabled)
        #expect(menu.state.launchTitle == VMLaunchPhase.checking.buttonTitle)
        let download = FactoryDownloadProgress(phase: .downloading, completedBytes: 1, totalBytes: 4)
        menu.launchDidDownload(download)
        #expect(menu.state.launchTitle == download.title)
        menu.launchDidFinishDownload()
        #expect(menu.state.launchTitle == VMLaunchPhase.checking.buttonTitle)
        menu.launchDidProgress(to: .starting)
        #expect(menu.state.launchTitle == VMLaunchPhase.starting.buttonTitle)

        menu.virtualMachineDidStart { closeCount += 1 }
        #expect(menu.state.launchTitle == "Done")
        #expect(menu.state.launchEnabled)
        #expect(menu.window.level == .floating)
        menu.actions.launchOrDone()
        #expect(closeCount == 1)
        #expect(launchCount == 1)
    }

    @Test("Enabling automatic startup requires confirmation before saving", arguments: [true, false])
    func confirmsAutomaticStartup(confirmed: Bool) {
        _ = NSApplication.shared
        var automaticStart = false
        var launchCount = 0
        var confirmationCount = 0
        let menu = makeMenu(
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
        #expect(!menu.state.startAutomatically)
        menu.changeStartAutomatically(true)
        #expect(automaticStart == confirmed)
        #expect(menu.state.startAutomatically == confirmed)
        #expect(confirmationCount == 1)
        #expect(launchCount == 0)

        menu.launchOmarchy()
        menu.launchOmarchy()
        #expect(launchCount == 1)
        #expect(!menu.window.isVisible)
        #expect(menu.state.startAutomatically == confirmed)
        #expect(!menu.state.settingsEnabled)
    }

    @Test("A failed startup preference write restores the switch and explains the error", arguments: [false, true])
    func failedStartupSave(wasEnabled: Bool) {
        _ = NSApplication.shared
        var attempts = 0
        var errorsPresented = 0
        let menu = makeMenu(
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
        menu.changeStartAutomatically(!wasEnabled)
        #expect(attempts == 1)
        #expect(menu.state.startAutomatically == wasEnabled)
        #expect(errorsPresented == 1)
    }

    @Test("Running settings can change startup and close without launching or quitting the VM")
    func runningSettings() {
        _ = NSApplication.shared
        var automaticStart = true
        var launchCount = 0
        var closeCount = 0
        let menu = makeMenu(
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
        #expect(menu.state.settingsEnabled)
        menu.changeStartAutomatically(false)
        #expect(!automaticStart)
        #expect(menu.state.runningActionsEnabled)
        #expect(!menu.state.manageStorageEnabled)

        menu.shutdownDidBegin()
        #expect(!menu.state.settingsEnabled)
        #expect(!menu.state.runningActionsEnabled)
        menu.launchOmarchy()
        #expect(launchCount == 1)
        #expect(menu.state.launchEnabled)
        menu.actions.launchOrDone()
        #expect(closeCount == 1)
        #expect(menu.windowShouldClose(menu.window) == false)
        #expect(closeCount == 2)
        #expect(launchCount == 1)
    }

    @Test("the camera notch setting shows only on a Mac with a notch and saves its choice")
    func cameraNotchSetting() {
        _ = NSApplication.shared
        let plain = makeMenu()
        defer { plain.dismiss() }
        plain.prepareForPresentation(visibleFrame: nil)
        #expect(!plain.state.notchAvailable)

        var usesNotch = true
        let notched = makeMenu(notchAvailable: { true }, usesNotch: { usesNotch }, setUsesNotch: { usesNotch = $0 })
        defer { notched.dismiss() }
        notched.prepareForPresentation(visibleFrame: nil)
        #expect(notched.state.notchAvailable)
        #expect(notched.state.usesNotch)
        notched.actions.setUsesNotch(false)
        #expect(!usesNotch)
        #expect(!notched.state.usesNotch)
    }

    @Test("returning to the launcher keeps its view and skips storage probes")
    func activationPreservesLauncher() throws {
        _ = NSApplication.shared
        var storageReads = 0
        var granted = false
        let menu = makeMenu(
            storageState: { storageReads += 1; return .defaultLocation },
            accessibilityStatus: { granted }
        )
        defer { menu.dismiss() }
        menu.prepareForPresentation(visibleFrame: nil)
        let host = try #require(menu.window.contentViewController)
        let initialReads = storageReads
        let frame = menu.window.frame
        #expect(menu.state.pendingPermissions == [.accessibility])
        #expect(menu.state.attentionCount(for: .permissions) == 1)

        for _ in 0..<10 { menu.applicationDidBecomeActive() }
        granted = true
        menu.applicationDidBecomeActive()

        #expect(storageReads == initialReads)
        #expect(menu.window.frame == frame)
        #expect(menu.window.contentViewController === host)
        #expect(menu.state.accessibility.isGranted)
        #expect(menu.state.pendingPermissions.isEmpty)
        #expect(menu.state.attentionCount(for: .permissions) == 0)
    }

    @Test("the first launch with unanswered permissions offers them once before starting")
    func firstLaunchPermissionPrompt() {
        _ = NSApplication.shared
        var launchCount = 0
        var promptShown = false
        let menu = makeMenu(
            accessibilityStatus: { false },
            microphoneStatus: { .notDetermined },
            cameraStatus: { .denied },
            permissionPromptShown: { promptShown },
            setPermissionPromptShown: { promptShown = true },
            launch: { launchCount += 1 }
        )
        defer { menu.dismiss() }
        menu.prepareForPresentation(visibleFrame: nil)
        // A denied camera was answered, so only the open questions remain.
        #expect(menu.state.pendingPermissions == [.accessibility, .microphone])
        #expect(menu.state.attentionCount(for: .permissions) == 2)

        menu.actions.launchOrDone()
        #expect(menu.state.permissionPromptPresented)
        #expect(promptShown)
        #expect(launchCount == 0)

        menu.actions.dismissPermissionPrompt()
        #expect(!menu.state.permissionPromptPresented)
        menu.actions.launchOrDone()
        #expect(!menu.state.permissionPromptPresented)
        #expect(launchCount == 1)
        #expect(menu.state.getStartedPermissions == [.accessibility, .microphone])

        // After the first boot, Home stops walking through permissions and
        // only missing Accessibility keeps the Permissions badge.
        menu.virtualMachineDidStart {}
        #expect(menu.state.getStartedPermissions.isEmpty)
        #expect(menu.state.attentionCount(for: .permissions) == 1)
    }

    @Test("launching anyway from the permission prompt starts Omarchy")
    func permissionPromptLaunchAnyway() {
        _ = NSApplication.shared
        var launchCount = 0
        let menu = makeMenu(
            microphoneStatus: { .notDetermined },
            permissionPromptShown: { false },
            launch: { launchCount += 1 }
        )
        defer { menu.dismiss() }
        menu.prepareForPresentation(visibleFrame: nil)
        menu.actions.launchOrDone()
        #expect(menu.state.permissionPromptPresented)
        menu.actions.launchAnyway()
        #expect(!menu.state.permissionPromptPresented)
        #expect(launchCount == 1)
    }

    @Test("permission completion updates in place and never resurrects a hidden launcher",
          arguments: [false, true], [false, true])
    func permissionCompletion(camera: Bool, allowed: Bool) async throws {
        _ = NSApplication.shared
        var storageReads = 0
        var finished = false
        var completion: ((Bool) -> Void)?
        let status: () -> MicrophoneAuthorizationState = {
            finished ? (allowed ? .authorized : .denied) : .notDetermined
        }
        let menu = makeMenu(
            storageState: { storageReads += 1; return .defaultLocation },
            microphoneStatus: status,
            cameraStatus: {
                switch status() {
                case .authorized: .authorized
                case .denied: .denied
                default: .notDetermined
                }
            },
            requestPermission: { completion = $0 }
        )
        defer { menu.dismiss() }
        menu.prepareForPresentation(visibleFrame: nil)
        let host = try #require(menu.window.contentViewController)
        let frame = menu.window.frame
        let initialReads = storageReads

        if camera { menu.actions.cameraAction() } else { menu.actions.microphoneAction() }
        let finish = try #require(completion)
        #expect(menu.state.permissionRequestInFlight)
        #expect(!menu.state.launchEnabled)
        #expect(!menu.state.settingsEnabled)
        let presentation = camera ? menu.state.camera : menu.state.microphone
        #expect(presentation.actionTitle == "Waiting…")
        menu.applicationDidBecomeActive()
        #expect(storageReads == initialReads)
        menu.prepareForPresentation(visibleFrame: nil)
        #expect(!menu.state.launchEnabled)
        let readsAfterPresentation = storageReads

        menu.dismiss()
        finished = true
        finish(allowed)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        #expect(!menu.window.isVisible)
        #expect(menu.window.frame == frame)
        #expect(menu.window.contentViewController === host)
        #expect(storageReads == readsAfterPresentation)
        #expect(menu.state.launchEnabled)
        let result = camera ? menu.state.camera : menu.state.microphone
        #expect(result.isGranted == allowed)
        #expect(result.actionTitle == (allowed ? nil : "Open Settings"))
    }

    @Test("the USB device names the chosen device and asks for attention when unplugged")
    func usbDevice() {
        _ = NSApplication.shared
        var connected = true
        let menu = makeMenu(usbState: {
            USBDeviceMenuState(
                device: USBDeviceIdentity(vendorId: 0x05AC, productId: 0x12A8, name: "iPhone"),
                isEnabled: true,
                isConnected: connected,
                environmentOverride: nil
            )
        })
        defer { menu.dismiss() }
        menu.prepareForPresentation(visibleFrame: nil)
        #expect(menu.state.usbDevice.compactDetailLines?.first?.contains("iPhone") == true)
        #expect(menu.state.usbDevice.toggleActionTitle == "Turn Off")
        #expect(menu.state.attentionCount(for: .sharing) == 0)

        connected = false
        menu.prepareForPresentation(visibleFrame: nil)
        #expect(menu.state.attentionItems.map(\.kind) == [.usb])
        #expect(menu.state.attentionCount(for: .sharing) == 1)
    }

    @Test("the USB device still offers a choice before any device is chosen")
    func usbDeviceWhileEmpty() {
        _ = NSApplication.shared
        let menu = makeMenu()
        defer { menu.dismiss() }
        menu.prepareForPresentation(visibleFrame: nil)
        #expect(menu.state.usbDevice.detail.hasPrefix("Optional."))
        #expect(menu.state.usbDevice.toggleActionTitle == nil)
        #expect(menu.state.usbDevice.actionsEnabled)
    }

    @Test("the selected VM reports its drive, warnings, overrides, and problems")
    func storageSummary() {
        let path = "~/Downloads/vm"
        let custom = StorageLocationMenuState(
            containerPath: "/Users/test/Downloads/vm", stateRoot: "/Users/test/Downloads/vm",
            displayPath: path, volumeName: "Studio", isDefault: false, isExternal: true,
            problem: nil, warning: nil, isEnvironmentOverride: false
        )
        let summary = LauncherState.storageSummary(path: path, status: custom, moving: false, canOpen: true)
        #expect(summary.lines == [path, "Studio · External drive"])
        #expect(summary.canOpenInFinder)

        let warned = StorageLocationMenuState(
            containerPath: nil, stateRoot: nil, displayPath: path, volumeName: "Macintosh HD",
            isDefault: false, isExternal: false, problem: nil,
            warning: "Macintosh HD has 18.3 GB free.", isEnvironmentOverride: false
        )
        #expect(LauncherState.storageSummary(path: path, status: warned, moving: false, canOpen: true).lines
            == [path, "Macintosh HD has 18.3 GB free."])

        let overridden = StorageLocationMenuState(
            containerPath: nil, stateRoot: nil, displayPath: path, volumeName: nil,
            isDefault: false, isExternal: false, problem: nil, warning: nil, isEnvironmentOverride: true
        )
        let overrideSummary = LauncherState.storageSummary(path: path, status: overridden, moving: false, canOpen: true)
        #expect(overrideSummary.lines == [path, "Set by \(StorageLocationPolicy.environmentKey)"])

        let missing = StorageLocationMenuState(
            containerPath: nil, stateRoot: nil, displayPath: path, volumeName: nil,
            isDefault: false, isExternal: true, problem: "The drive is not connected.",
            warning: nil, isEnvironmentOverride: false
        )
        let missingSummary = LauncherState.storageSummary(path: path, status: missing, moving: false, canOpen: true)
        #expect(missingSummary.lines == [path])
        #expect(missingSummary.problem == "The drive is not connected.")
        #expect(!missingSummary.canOpenInFinder)

        let moving = LauncherState.storageSummary(path: path, status: custom, moving: true, canOpen: true)
        #expect(moving.lines == ["Copying and verifying your VM… Original retained."])
        #expect(!moving.canOpenInFinder)
    }

    @Test("an environment-selected VM cannot be managed and a missing drive needs attention")
    func storageRules() {
        _ = NSApplication.shared
        var status = StorageLocationMenuState(
            containerPath: "/tmp/vm", stateRoot: "/tmp/vm", displayPath: "/tmp/vm", volumeName: nil,
            isDefault: false, isExternal: false, problem: nil, warning: nil, isEnvironmentOverride: true
        )
        let menu = makeMenu(storageState: { status })
        defer { menu.dismiss() }
        menu.prepareForPresentation(visibleFrame: nil)
        #expect(!menu.state.manageStorageEnabled)

        status = StorageLocationMenuState(
            containerPath: "/Volumes/Gone/vm", stateRoot: nil, displayPath: "/Volumes/Gone/vm", volumeName: nil,
            isDefault: false, isExternal: true, problem: "The drive is not connected.", warning: nil,
            isEnvironmentOverride: false
        )
        menu.prepareForPresentation(visibleFrame: nil)
        #expect(menu.state.manageStorageEnabled)
        #expect(menu.state.attentionItems.map(\.kind) == [.storage])
        #expect(menu.state.attentionCount(for: .virtualMachine) == 1)
    }

    @Test("bridged networking explains a missing adapter or helper")
    func networkSummary() {
        #expect(LauncherState.networkSummary(VMNetworkPreferences(), bridgeAvailable: false, serviceEnabled: false)
            == ("Shared (NAT) · Uses your Mac’s connection", nil))
        var bridged = VMNetworkPreferences()
        bridged.mode = .bridged
        bridged.interface = "en7"
        #expect(LauncherState.networkSummary(bridged, bridgeAvailable: true, serviceEnabled: true)
            == ("Bridged via en7", nil))
        #expect(LauncherState.networkSummary(bridged, bridgeAvailable: false, serviceEnabled: true).warning
            == "Adapter unavailable — Omarchy will start offline")
        #expect(LauncherState.networkSummary(bridged, bridgeAvailable: true, serviceEnabled: false).warning
            == "Networking helper setup required")
    }

    @Test("reset settings asks once and keeps settings when cancelled", arguments: [false, true])
    func settingsReset(confirmed: Bool) {
        _ = NSApplication.shared
        var resets = 0
        var shown: [String] = []
        let menu = makeMenu(
            resetSettings: { resets += 1 },
            presentSettingsResetConfirmation: { alert, _, decide in
                shown.append(alert.messageText)
                decide(confirmed)
            }
        )
        defer { menu.dismiss() }
        menu.prepareForPresentation(visibleFrame: nil)
        menu.actions.resetSettings()
        #expect(shown == ["Reset all settings?"])
        #expect(resets == (confirmed ? 1 : 0))
        #expect(menu.state.settingsEnabled)
    }

    @Test("a disposable VM cannot be managed and hides its location")
    func disposableVM() {
        _ = NSApplication.shared
        let menu = makeMenu(canResetStorage: false, storageLocation: { nil })
        defer { menu.dismiss() }
        menu.prepareForPresentation(visibleFrame: nil)
        #expect(menu.state.storage == nil)
        #expect(!menu.state.manageStorageEnabled)
    }

    private func makeMenu(
        storageState: @escaping () -> StorageLocationMenuState = { .defaultLocation },
        canResetStorage: Bool = true,
        storageLocation: (() -> String?)? = nil,
        accessibilityStatus: @escaping () -> Bool = { true },
        microphoneStatus: @escaping () -> MicrophoneAuthorizationState = { .authorized },
        cameraStatus: @escaping () -> CameraAuthorizationState = { .authorized },
        requestPermission: ((@escaping (Bool) -> Void) -> Void)? = nil,
        usbState: @escaping () -> USBDeviceMenuState = { .disabled },
        resetSettings: @escaping () -> Void = {},
        notchAvailable: @escaping () -> Bool = { false },
        usesNotch: @escaping () -> Bool = { true },
        setUsesNotch: @escaping (Bool) -> Void = { _ in },
        startAutomatically: @escaping () -> Bool = { false },
        setStartAutomatically: @escaping (Bool) -> String? = { _ in nil },
        presentStartupSaveError: @escaping (NSAlert, NSWindow) -> Void = { _, _ in },
        confirmAutomaticStartup: @escaping (NSAlert) -> NSApplication.ModalResponse = { _ in .alertFirstButtonReturn },
        presentSettingsResetConfirmation: @escaping (NSAlert, NSWindow, @escaping (Bool) -> Void) -> Void = { _, _, _ in },
        permissionPromptShown: @escaping () -> Bool = { true },
        setPermissionPromptShown: @escaping () -> Void = {},
        launch: @escaping () -> Void = {}
    ) -> StartMenuWindow {
        let request: (@escaping (Bool) -> Void) -> Void = { completion in
            if let requestPermission { requestPermission(completion) } else { completion(true) }
        }
        return StartMenuWindow(
            accessibilityStatus: accessibilityStatus,
            microphoneStatus: microphoneStatus,
            cameraStatus: cameraStatus,
            requestAccessibility: {},
            requestMicrophone: request,
            requestCamera: request,
            canResetStorage: canResetStorage,
            storageLocation: storageLocation ?? { storageState().displayPath ?? "~/Library/Application Support/Try Omarchy" },
            storageLocationURL: { storageState().containerPath.map { URL(fileURLWithPath: $0) } },
            storageLocationStatus: storageState,
            validateStorageLocation: { _ in nil },
            chooseStorageLocation: { _ in nil },
            useDefaultStorageLocation: {},
            resetSettings: resetSettings,
            sharedFolderStatus: { .disabled },
            chooseSharedFolder: { _ in nil },
            setSharedFolderEnabled: { _ in },
            usbDeviceStatus: usbState,
            connectedUSBDevices: { [] },
            saveUSBDevice: { _ in },
            portForwardingStatus: { [] },
            immersiveMode: { true },
            setImmersiveMode: { _ in },
            notchAvailable: notchAvailable,
            usesNotch: usesNotch,
            setUsesNotch: setUsesNotch,
            startAutomatically: startAutomatically,
            setStartAutomatically: setStartAutomatically,
            presentStartupSaveError: presentStartupSaveError,
            confirmAutomaticStartup: confirmAutomaticStartup,
            presentSettingsResetConfirmation: presentSettingsResetConfirmation,
            permissionPromptShown: permissionPromptShown,
            setPermissionPromptShown: setPermissionPromptShown,
            launch: launch
        )
    }
}
