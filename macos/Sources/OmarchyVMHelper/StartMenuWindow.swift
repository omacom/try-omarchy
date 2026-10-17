import AppKit
import SwiftUI

enum VMDestructiveConfirmationPolicy {
    static let requiredText = "Try Omarchy"

    static func allowsAction(_ text: String) -> Bool {
        text == requiredText
    }
}

@MainActor
final class VMDestructiveConfirmationPrompt {
    let alert: NSAlert
    let confirmationField: NSTextField
    let actionButton: NSButton

    private var textChangeObserver: NSObjectProtocol?

    enum Action: String { case reset, delete }

    init(detail: String, action: Action = .reset) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = action == .reset ? "Reset Omarchy to factory settings?" : "Delete the selected VM?"
        alert.informativeText = detail
        alert.addButton(withTitle: "Cancel")
        let actionButton = alert.addButton(withTitle: action == .reset ? "Reset" : "Move to Trash")
        actionButton.hasDestructiveAction = true
        actionButton.isEnabled = false

        let instruction = NSTextField(
            labelWithString: "Type \(VMDestructiveConfirmationPolicy.requiredText) to confirm"
        )
        instruction.font = .systemFont(ofSize: 12, weight: .medium)
        instruction.translatesAutoresizingMaskIntoConstraints = false

        let confirmationField = NSTextField(string: "")
        confirmationField.placeholderString = VMDestructiveConfirmationPolicy.requiredText
        confirmationField.identifier = NSUserInterfaceItemIdentifier("\(action.rawValue)-confirmation-field")
        confirmationField.setAccessibilityLabel(
            "Type \(VMDestructiveConfirmationPolicy.requiredText) to confirm \(action.rawValue)"
        )
        confirmationField.translatesAutoresizingMaskIntoConstraints = false

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 52))
        accessory.addSubview(instruction)
        accessory.addSubview(confirmationField)
        NSLayoutConstraint.activate([
            instruction.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            instruction.trailingAnchor.constraint(lessThanOrEqualTo: accessory.trailingAnchor),
            instruction.topAnchor.constraint(equalTo: accessory.topAnchor),
            confirmationField.leadingAnchor.constraint(equalTo: accessory.leadingAnchor),
            confirmationField.trailingAnchor.constraint(equalTo: accessory.trailingAnchor),
            confirmationField.topAnchor.constraint(equalTo: instruction.bottomAnchor, constant: 7),
            confirmationField.bottomAnchor.constraint(equalTo: accessory.bottomAnchor),
        ])
        alert.accessoryView = accessory

        self.alert = alert
        self.confirmationField = confirmationField
        self.actionButton = actionButton
        textChangeObserver = NotificationCenter.default.addObserver(
            forName: NSControl.textDidChangeNotification,
            object: confirmationField,
            queue: .main
        ) { [weak confirmationField, weak actionButton] _ in
            actionButton?.isEnabled = VMDestructiveConfirmationPolicy.allowsAction(
                confirmationField?.stringValue ?? ""
            )
        }
    }

    deinit {
        if let textChangeObserver {
            NotificationCenter.default.removeObserver(textChangeObserver)
        }
    }

    func present(for window: NSWindow, completion: @escaping (Bool) -> Void) {
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else {
                completion(false)
                return
            }
            let confirmed = response == .alertSecondButtonReturn
                && VMDestructiveConfirmationPolicy.allowsAction(confirmationField.stringValue)
            completion(confirmed)
        }
        DispatchQueue.main.async { [weak window, weak confirmationField] in
            guard let window, let confirmationField else { return }
            window.makeFirstResponder(confirmationField)
        }
    }

    func cancel(in window: NSWindow) {
        guard window.attachedSheet === alert.window else { return }
        window.endSheet(alert.window, returnCode: .alertFirstButtonReturn)
    }
}

@MainActor
enum StartMenuWindowChrome {
    static let contentSize = NSSize(width: 860, height: 600)
    static let minimumContentSize = NSSize(width: 760, height: 500)

    static func apply(to window: NSWindow) {
        window.title = "Try Omarchy"
        // Each pane draws its own title beside the window buttons.
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        // Let the panes run under the toolbar instead of a separate gray band.
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.contentMinSize = minimumContentSize
        // Follow the system Light or Dark appearance like other Mac apps.
        window.appearance = nil
    }
}

@MainActor
final class StartMenuWindow: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow
    let state = LauncherState()
    private(set) var actions = LauncherActions()
    private let accessibilityStatus: () -> Bool
    private let microphoneStatus: () -> MicrophoneAuthorizationState
    private let cameraStatus: () -> CameraAuthorizationState
    private let requestAccessibility: () -> Void
    private let requestMicrophone: (@escaping (Bool) -> Void) -> Void
    private let requestCamera: (@escaping (Bool) -> Void) -> Void
    private let storageSpaceEstimate: () -> String?
    private let resetStorage: () -> Void
    private let sharedFolderStatus: () -> SharedFolderMenuState
    private let chooseSharedFolder: (String) -> String?
    private let setSharedFolderEnabled: (Bool) -> Void
    private let usbDeviceStatus: () -> USBDeviceMenuState
    private let connectedUSBDevices: () -> [USBDeviceIdentity]
    private let saveUSBDevice: (USBDevicePreference) -> Void
    private let portForwardingStatus: () -> [PortForwardMapping]
    private let savePortForwarding: ([PortForwardMapping]) -> String?
    private let resources: () -> VMResources
    private let minimumDiskGiB: () -> Int
    private let resourceLimits: VMResourceLimits
    private let saveResources: (VMResources) -> Void
    private let networkPreferences: () -> VMNetworkPreferences
    private let saveNetworkPreferences: (VMNetworkPreferences) -> String?
    private let networkIdentity: VMNetworkIdentityAccess
    private var networkEditor: NetworkEditor?
    private let immersiveMode: () -> Bool
    private let setImmersiveMode: (Bool) -> Void
    private let notchAvailable: () -> Bool
    private let usesNotch: () -> Bool
    private let setUsesNotch: (Bool) -> Void
    private let startAutomatically: () -> Bool
    private let setStartAutomatically: (Bool) -> String?
    private let presentStartupSaveError: (NSAlert, NSWindow) -> Void
    private let confirmAutomaticStartup: (NSAlert) -> NSApplication.ModalResponse
    private let launch: () -> Void
    private let appReleaseActionTitle: () -> String
    private let checkForAppUpdates: () -> Void
    private let canResetStorage: Bool
    private let storageLocation: () -> String?
    private let storageLocationURL: () -> URL?
    private let storageLocationStatus: () -> StorageLocationMenuState
    private let validateStorageLocation: (String) -> String?
    private let chooseStorageLocation: (String) -> String?
    private let deleteStorageLocation: VMStorageEditor.Delete
    private let moveStorageLocation: VMStorageEditor.Move
    private let useDefaultStorageLocation: () -> Void

    private var closeRunningSettings: (() -> Void)?
    private var requestSettingsAction: ((VMRunLifecycle.SettingsAction) -> Void)?
    private var controlsBusy: Bool { state.controlsBusy }
    var onAppReleasePromptOpportunity: (() -> Void)?
    var canPresentAppReleasePrompt: Bool {
        window.isKeyWindow && !controlsBusy && !state.resetInProgress
            && !state.permissionRequestInFlight
            && window.attachedSheet == nil && networkEditor == nil
            && portForwardingEditor == nil && resourceEditor == nil && usbDeviceEditor == nil
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onAppReleasePromptOpportunity?()
    }
    private var prelaunchControlsLocked: Bool { state.prelaunchLocked }
    private var pendingResetSpaceEstimate: String?
    private var resetConfirmationPrompt: VMDestructiveConfirmationPrompt?
    private(set) var portForwardingEditor: PortForwardingEditor?
    private(set) var resourceEditor: VMResourceEditor?
    private(set) var usbDeviceEditor: USBDeviceEditor?
    private(set) var storageEditor: VMStorageEditor? {
        didSet { state.storageEditorOpen = storageEditor != nil }
    }

    init(
        accessibilityStatus: @escaping () -> Bool,
        microphoneStatus: @escaping () -> MicrophoneAuthorizationState,
        cameraStatus: @escaping () -> CameraAuthorizationState = { .authorized },
        requestAccessibility: @escaping () -> Void,
        requestMicrophone: @escaping (@escaping (Bool) -> Void) -> Void,
        requestCamera: @escaping (@escaping (Bool) -> Void) -> Void = { completion in
            completion(true)
        },
        canResetStorage: Bool,
        storageLocation: @escaping () -> String?,
        storageLocationURL: @escaping () -> URL?,
        storageSpaceEstimate: @escaping () -> String?,
        storageLocationStatus: @escaping () -> StorageLocationMenuState,
        validateStorageLocation: @escaping (String) -> String?,
        chooseStorageLocation: @escaping (String) -> String?,
        useDefaultStorageLocation: @escaping () -> Void,
        resetStorage: @escaping () -> Void,
        deleteStorageLocation: @escaping VMStorageEditor.Delete = { _, _, completion in completion("VM deletion is unavailable.") },
        moveStorageLocation: @escaping VMStorageEditor.Move = { _, _, _, completion in completion("VM relocation is unavailable.") },
        sharedFolderStatus: @escaping () -> SharedFolderMenuState,
        chooseSharedFolder: @escaping (String) -> String?,
        setSharedFolderEnabled: @escaping (Bool) -> Void,
        usbDeviceStatus: @escaping () -> USBDeviceMenuState = { .disabled },
        connectedUSBDevices: @escaping () -> [USBDeviceIdentity] = { [] },
        saveUSBDevice: @escaping (USBDevicePreference) -> Void = { _ in },
        portForwardingStatus: @escaping () -> [PortForwardMapping] = { [] },
        savePortForwarding: @escaping ([PortForwardMapping]) -> String? = { _ in nil },
        resources: @escaping () -> VMResources = { VMResourceLimits.current.defaults },
        resourceLimits: VMResourceLimits = .current,
        minimumDiskGiB: @escaping () -> Int = { 1 },
        saveResources: @escaping (VMResources) -> Void = { _ in },
        networkPreferences: @escaping () -> VMNetworkPreferences = { VMNetworkPreferences() },
        saveNetworkPreferences: @escaping (VMNetworkPreferences) -> String? = { _ in nil },
        networkIdentity: VMNetworkIdentityAccess = .unavailable,
        immersiveMode: @escaping () -> Bool = { true },
        setImmersiveMode: @escaping (Bool) -> Void = { _ in },
        notchAvailable: @escaping () -> Bool = { false },
        usesNotch: @escaping () -> Bool = { true },
        setUsesNotch: @escaping (Bool) -> Void = { _ in },
        startAutomatically: @escaping () -> Bool = { false },
        setStartAutomatically: @escaping (Bool) -> String? = { _ in nil },
        presentStartupSaveError: @escaping (NSAlert, NSWindow) -> Void = { $0.beginSheetModal(for: $1) },
        confirmAutomaticStartup: @escaping (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() },
        appVersionLabel: String = InstalledAppRelease.current.label,
        appReleaseActionTitle: @escaping () -> String = { "Check for Updates…" },
        checkForAppUpdates: @escaping () -> Void = {},
        launch: @escaping () -> Void
    ) {
        self.accessibilityStatus = accessibilityStatus
        self.microphoneStatus = microphoneStatus
        self.cameraStatus = cameraStatus
        self.requestAccessibility = requestAccessibility
        self.requestMicrophone = requestMicrophone
        self.requestCamera = requestCamera
        self.canResetStorage = canResetStorage
        self.storageLocation = storageLocation
        self.storageLocationURL = storageLocationURL
        self.storageSpaceEstimate = storageSpaceEstimate
        self.storageLocationStatus = storageLocationStatus
        self.validateStorageLocation = validateStorageLocation
        self.chooseStorageLocation = chooseStorageLocation
        self.deleteStorageLocation = deleteStorageLocation
        self.moveStorageLocation = moveStorageLocation
        self.useDefaultStorageLocation = useDefaultStorageLocation
        self.resetStorage = resetStorage
        self.sharedFolderStatus = sharedFolderStatus
        self.chooseSharedFolder = chooseSharedFolder
        self.setSharedFolderEnabled = setSharedFolderEnabled
        self.usbDeviceStatus = usbDeviceStatus
        self.connectedUSBDevices = connectedUSBDevices
        self.saveUSBDevice = saveUSBDevice
        self.portForwardingStatus = portForwardingStatus
        self.savePortForwarding = savePortForwarding
        self.resources = resources
        self.minimumDiskGiB = minimumDiskGiB
        self.resourceLimits = resourceLimits
        self.saveResources = saveResources
        self.networkPreferences = networkPreferences
        self.saveNetworkPreferences = saveNetworkPreferences
        self.networkIdentity = networkIdentity
        self.immersiveMode = immersiveMode
        self.setImmersiveMode = setImmersiveMode
        self.notchAvailable = notchAvailable
        self.usesNotch = usesNotch
        self.setUsesNotch = setUsesNotch
        self.startAutomatically = startAutomatically
        self.setStartAutomatically = setStartAutomatically
        self.presentStartupSaveError = presentStartupSaveError
        self.confirmAutomaticStartup = confirmAutomaticStartup
        self.launch = launch
        self.appReleaseActionTitle = appReleaseActionTitle
        self.checkForAppUpdates = checkForAppUpdates

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: StartMenuWindowChrome.contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        state.canResetStorage = canResetStorage
        state.appVersionLabel = appVersionLabel
        actions = makeActions()
        let host = NSHostingController(rootView: LauncherView(state: state, actions: actions))
        // Panes draw their own titles; bridging would show a second one.
        host.sceneBridgingOptions = []
        host.sizingOptions = []
        window.contentViewController = host
        StartMenuWindowChrome.apply(to: window)
        window.setContentSize(StartMenuWindowChrome.contentSize)
        window.delegate = self
    }

    private func makeActions() -> LauncherActions {
        LauncherActions(
            launchOrDone: { [weak self] in
                guard let self else { return }
                if state.isRunning { closeSettings() } else { launchOmarchy() }
            },
            accessibilityAction: { [weak self] in self?.beginAccessibilityRequest() },
            microphoneAction: { [weak self] in
                guard let self else { return }
                if state.microphone.action == .openSettings {
                    openPrivacySettings("Privacy_Microphone")
                } else {
                    beginMicrophoneRequest()
                }
            },
            cameraAction: { [weak self] in
                guard let self else { return }
                if state.camera.action == .openSettings {
                    openPrivacySettings("Privacy_Camera")
                } else {
                    beginCameraRequest()
                }
            },
            chooseSharedFolder: { [weak self] in self?.beginSharedFolderSelection() },
            setSharedFolderEnabled: { [weak self] in self?.changeSharedFolderEnabled($0) },
            chooseUSBDevice: { [weak self] in self?.beginUSBDeviceSelection() },
            setUSBDeviceEnabled: { [weak self] in self?.changeUSBDeviceEnabled($0) },
            configureNetwork: { [weak self] in self?.beginNetworkConfiguration() },
            configurePortForwarding: { [weak self] in self?.beginPortForwardingConfiguration() },
            configureResources: { [weak self] in self?.beginResourceConfiguration() },
            manageStorage: { [weak self] in self?.showStorageActions() },
            openStorageLocation: { [weak self] in self?.openStorageLocation() },
            setImmersive: { [weak self] in self?.changeImmersiveMode($0) },
            setUsesNotch: { [weak self] in self?.changeNotchMode($0) },
            setStartAutomatically: { [weak self] in self?.changeStartAutomatically($0) },
            reset: { [weak self] in self?.confirmReset() },
            restart: { [weak self] in self?.requestShutdown(.restart) },
            shutDown: { [weak self] in self?.requestShutdown(.manage) },
            checkForUpdates: { [weak self] in self?.checkForAppUpdates() }
        )
    }

    func virtualMachineDidStart(
        requestSettingsAction: @escaping (VMRunLifecycle.SettingsAction) -> Void = { _ in },
        closeSettings: @escaping () -> Void
    ) {
        state.launchInProgress = false
        state.isRunning = true
        closeRunningSettings = closeSettings
        self.requestSettingsAction = requestSettingsAction
        // The VM has its own Cocoa process and may occupy a fullscreen Space.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.level = .floating
    }

    func shutdownDidBegin() {
        state.shutdownInProgress = true
        refresh()
    }

    func shutdownDidFail(_ message: String) {
        state.shutdownInProgress = false
        refresh()
        let alert = NSAlert()
        alert.messageText = "Omarchy couldn’t shut down"
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    private func requestShutdown(_ action: VMRunLifecycle.SettingsAction) {
        guard state.isRunning, !controlsBusy, !state.permissionRequestInFlight,
              window.attachedSheet == nil, portForwardingEditor == nil else { return }
        let alert = NSAlert()
        alert.messageText = action == .restart ? "Restart Try Omarchy?" : "Shut down Omarchy to manage this VM?"
        alert.informativeText = action == .restart
            ? "Save your work first. Omarchy will shut down and start again with your saved settings."
            : "Save your work first. The settings window will stay open so you can change the VM location or reset it."
        alert.addButton(withTitle: action == .restart ? "Restart" : "Shut Down")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.requestSettingsAction?(action)
        }
    }

    private func closeSettings() {
        guard state.isRunning else { return }
        dismiss()
        closeRunningSettings?()
    }

    func show() {
        prepareForPresentation(
            visibleFrame: (window.screen ?? NSScreen.main)?.visibleFrame
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Reuse the current view hierarchy so open editors keep their drafts.
    func bringToFront() {
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        window.attachedSheet?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func refreshAppReleaseStatus() {
        state.appReleaseActionTitle = appReleaseActionTitle()
    }

    func prepareForPresentation(visibleFrame: NSRect?) {
        refresh()
        guard let visibleFrame else { return }
        let available = window.contentRect(forFrameRect: visibleFrame.insetBy(dx: 0, dy: 16)).size
        let size = NSSize(
            width: min(StartMenuWindowChrome.contentSize.width, max(1, available.width)),
            height: min(StartMenuWindowChrome.contentSize.height, max(1, available.height))
        )
        if window.contentRect(forFrameRect: window.frame).size != size, !window.isVisible {
            window.setContentSize(size)
        }
    }

    func refreshPermissionStatus() {
        guard !controlsBusy, !state.resetInProgress else { return }
        updatePermissionState()
    }

    func applicationDidBecomeActive() {
        // Returning from Settings or a system prompt must not rebuild the
        // launcher, probe VM storage, or disturb an open sheet or its draft.
        refreshPermissionStatus()
    }

    private func updatePermissionState() {
        let granted = accessibilityStatus()
        state.accessibility = StartMenuPermissionPresentation(
            detail: "Needed for the native keyboard experience with Super shortcuts.",
            isGranted: granted,
            actionTitle: granted ? nil : "Open Settings",
            action: .request
        )
        state.microphone = StartMenuPresentation.microphone(
            state: microphoneStatus(), requestInFlight: state.microphoneRequestInFlight
        )
        state.camera = StartMenuPresentation.camera(
            state: cameraStatus(), requestInFlight: state.cameraRequestInFlight
        )
    }

    func promptForReset() {
        guard canResetStorage else { return }
        state.selectedPane = .virtualMachine
        window.makeKeyAndOrderFront(nil)
        confirmReset()
    }

    func dismiss() {
        resetConfirmationPrompt?.cancel(in: window)
        resetConfirmationPrompt = nil
        portForwardingEditor?.dismiss()
        portForwardingEditor = nil
        resourceEditor?.dismiss()
        resourceEditor = nil
        storageEditor?.dismiss()
        storageEditor = nil
        window.orderOut(nil)
    }

    func launchDidProgress(to phase: VMLaunchPhase) {
        guard state.launchInProgress, state.launchPhase != phase else { return }
        state.launchPhase = phase
        state.launchDownload = nil
        announce(phase.buttonTitle)
    }

    /// The download runs before the launcher; an automatic start shows the
    /// window so a long first download is never invisible.
    func launchDidDownload(_ progress: FactoryDownloadProgress) {
        guard state.launchInProgress, state.launchDownload != progress else { return }
        let phaseChanged = state.launchDownload?.phase != progress.phase
        state.launchDownload = progress
        if !window.isVisible { show() }
        if phaseChanged { announce(progress.title) }
    }

    func launchDidFinishDownload() {
        guard state.launchInProgress else { return }
        state.launchDownload = nil
    }

    func resetDidProgress(to phase: VMResetPhase) {
        guard state.resetInProgress, state.resetPhase != phase else { return }
        state.resetPhase = phase
        announce(phase.buttonTitle)
    }

    private func announce(_ text: String) {
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    func resetDidFinish(errorMessage: String?) {
        guard state.resetInProgress else { return }
        state.resetInProgress = false
        refresh()

        let alert = NSAlert()
        if let errorMessage {
            alert.alertStyle = .critical
            alert.messageText = "Omarchy couldn’t be reset"
            alert.informativeText = errorMessage
        } else {
            alert.alertStyle = .informational
            alert.messageText = "Try Omarchy has been reset"
            if let estimate = pendingResetSpaceEstimate {
                alert.informativeText = "The VM has been deleted. Up to \(estimate) of disk space was reclaimed. A fresh VM will be prepared on the next launch."
            } else {
                alert.informativeText = "The VM has been deleted. A fresh VM will be prepared on the next launch."
            }
        }
        pendingResetSpaceEstimate = nil
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    /// Clears the launching state when the controller stopped before the
    /// launcher was ever started. The controller presents its own explanation.
    func launchDidAbort() {
        guard state.launchInProgress else { return }
        state.launchInProgress = false
        state.launchDownload = nil
        show()
    }

    /// Clears the resetting state when the controller refused to start the
    /// reset at all. Deliberately silent, and deliberately not
    /// `resetDidFinish(errorMessage: nil)` — nothing was erased, so claiming
    /// "Try Omarchy has been reset" would be a lie about a destructive action.
    func resetDidAbort() {
        guard state.resetInProgress else { return }
        state.resetInProgress = false
        refresh()
    }

    func launchDidFail(errorMessage: String) {
        guard state.launchInProgress else { return }
        state.launchInProgress = false
        state.launchDownload = nil
        show()

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Try Omarchy couldn’t start"
        alert.informativeText = errorMessage
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if state.storageMoveInProgress { return false }
        if state.isRunning {
            closeSettings()
        } else {
            NSApp.terminate(nil)
        }
        return false
    }

    /// Reads every setting the launcher shows. Only explicit refreshes call
    /// this; app activation refreshes permissions alone.
    private func refresh() {
        defer { onAppReleasePromptOpportunity?() }
        updatePermissionState()

        let sharedFolder = sharedFolderStatus()
        state.sharedFolderState = sharedFolder
        state.sharedFolder = StartMenuPresentation.sharedFolder(state: sharedFolder)
        let usbDevice = usbDeviceStatus()
        state.usbDeviceState = usbDevice
        state.usbDevice = StartMenuPresentation.usbDevice(state: usbDevice)

        let network = networkPreferences()
        let networkSummary = LauncherState.networkSummary(
            network,
            bridgeAvailable: network.mode != .bridged
                || VMBridgeInterfaces.available().contains { $0.name == network.interface },
            serviceEnabled: network.mode != .bridged || NetworkService.service.status == .enabled
        )
        state.networkIsBridged = network.mode == .bridged
        state.networkDetail = networkSummary.detail
        state.networkWarning = networkSummary.warning
        let portMappings = portForwardingStatus()
        state.portCount = portMappings.count
        state.portForwarding = StartMenuPresentation.portForwarding(mappings: portMappings)

        let selectedResources = resources()
        state.resourcesSummary = StartMenuPresentation.resources(selectedResources)
        state.resourcesAreDefault = selectedResources == resourceLimits.defaults

        if let storagePath = storageLocation() {
            state.storage = LauncherState.storageSummary(
                path: storagePath,
                status: storageLocationStatus(),
                moving: state.storageMoveInProgress,
                canOpen: storageLocationURL() != nil
            )
        } else {
            state.storage = nil
        }
        let record = storageLocationURL().flatMap {
            ShellGuestStatusRecord.read($0.appendingPathComponent("shell/guest-status.json"))
        }
        state.guestReported = record?.report != nil
        state.guest = ShellGuestPresentation.make(
            record: record, bundledPackage: ShellGuestPresentation.bundledPackageVersion()
        )

        state.immersive = immersiveMode()
        state.notchAvailable = notchAvailable()
        state.usesNotch = usesNotch()
        state.startAutomatically = startAutomatically()
        state.appReleaseActionTitle = appReleaseActionTitle()
    }

    private func beginAccessibilityRequest() {
        requestAccessibility()
        updatePermissionState()
    }

    private func beginMicrophoneRequest() {
        guard microphoneStatus() == .notDetermined, !state.microphoneRequestInFlight else { return }
        state.microphoneRequestInFlight = true
        updatePermissionState()
        requestMicrophone { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.state.microphoneRequestInFlight = false
                self.updatePermissionState()
                self.onAppReleasePromptOpportunity?()
            }
        }
    }

    private func beginCameraRequest() {
        guard cameraStatus() == .notDetermined, !state.cameraRequestInFlight else { return }
        state.cameraRequestInFlight = true
        updatePermissionState()
        requestCamera { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.state.cameraRequestInFlight = false
                self.updatePermissionState()
                self.onAppReleasePromptOpportunity?()
            }
        }
    }

    private func openPrivacySettings(_ anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func openStorageLocation() {
        guard let storageLocationURL = storageLocationURL() else { return }
        do {
            if !FileManager.default.fileExists(atPath: storageLocationURL.path) {
                // Only the default folder is ever created from here. A chosen
                // folder that has gone missing means its drive is not mounted,
                // and "the parent exists" is not proof otherwise: a leftover
                // /Volumes/<name> directory on the boot volume satisfies that
                // test, so creating the folder would silently rebuild the
                // workspace on the internal disk and the next launch would
                // initialize a brand-new VM there.
                guard storageLocationStatus().isDefault else {
                    throw NSError(
                        domain: "TryOmarchy.StorageLocation",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "The drive that holds this folder is not connected. Reconnect it, or switch back to the default folder.",
                        ]
                    )
                }
                try FileManager.default.createDirectory(
                    at: storageLocationURL,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            guard NSWorkspace.shared.open(storageLocationURL) else {
                throw NSError(
                    domain: "TryOmarchy.StorageLocation",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Finder could not open the data directory."]
                )
            }
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t open the data directory"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window)
        }
    }

    private func showStorageActions() {
        guard canResetStorage, !prelaunchControlsLocked, !state.resetInProgress,
              !storageLocationStatus().isEnvironmentOverride, storageEditor == nil else { return }
        let editor = VMStorageEditor(
            selectedRoot: storageLocationURL,
            isDefault: { [weak self] in self?.storageLocationStatus().isDefault ?? true },
            validate: validateStorageLocation,
            select: chooseStorageLocation,
            useDefault: useDefaultStorageLocation,
            move: { [weak self] source, destination, progress, completion in
                guard let self else { completion("The launcher was closed."); return }
                self.state.storageMoveInProgress = true
                self.moveStorageLocation(source, destination, progress) { [weak self] error in
                    self?.state.storageMoveInProgress = false
                    completion(error)
                }
            },
            delete: { [weak self] source, identity, completion in
                guard let self else { completion("The launcher was closed."); return }
                self.state.storageMoveInProgress = true
                self.deleteStorageLocation(source, identity) { [weak self] error in
                    self?.state.storageMoveInProgress = false
                    completion(error)
                }
            },
            didClose: { [weak self] in
                self?.storageEditor = nil
                self?.refresh()
            }
        )
        storageEditor = editor
        refresh()
        editor.beginSheet(for: window)
    }

    private func beginSharedFolderSelection() {
        guard !controlsBusy, !state.resetInProgress, !state.permissionRequestInFlight else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a folder to share with Omarchy"
        panel.message = "Omarchy will be able to read and change everything inside this folder, linked as ~/<folder name>."
        panel.prompt = "Share"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        if let current = sharedFolderStatus().path {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let problem = chooseSharedFolder(url.path) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "That folder can’t be shared"
            alert.informativeText = problem
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window)
        }
        refresh()
    }

    private func changeSharedFolderEnabled(_ isEnabled: Bool) {
        guard !controlsBusy, !state.resetInProgress else { return }
        setSharedFolderEnabled(isEnabled)
        refresh()
    }

    private func beginUSBDeviceSelection() {
        guard !controlsBusy, !state.resetInProgress, !state.permissionRequestInFlight,
              usbDeviceEditor == nil, window.attachedSheet == nil else { return }
        let usbState = usbDeviceStatus()
        let editor = USBDeviceEditor(
            preference: USBDevicePreference(device: usbState.device, isEnabled: usbState.isEnabled),
            connected: connectedUSBDevices(),
            save: { [weak self] preference in self?.saveUSBDevice(preference) },
            didClose: { [weak self] in
                self?.usbDeviceEditor = nil
                self?.refresh()
            }
        )
        usbDeviceEditor = editor
        editor.beginSheet(for: window)
    }

    private func changeUSBDeviceEnabled(_ isEnabled: Bool) {
        guard !controlsBusy, !state.resetInProgress, let device = usbDeviceStatus().device else { return }
        saveUSBDevice(USBDevicePreference(device: device, isEnabled: isEnabled))
        refresh()
    }

    private func beginNetworkConfiguration() {
        guard !controlsBusy, !state.resetInProgress, networkEditor == nil else { return }
        let editor = NetworkEditor(preferences: networkPreferences(), interfaces: VMBridgeInterfaces.available(),
            identity: networkIdentity, save: saveNetworkPreferences, didClose: { [weak self] in
                self?.networkEditor = nil
                self?.refresh()
            })
        networkEditor = editor
        editor.beginSheet(for: window)
    }

    private func beginPortForwardingConfiguration() {
        guard !controlsBusy, !state.resetInProgress, portForwardingEditor == nil else { return }
        let editor = PortForwardingEditor(
            mappings: portForwardingStatus(),
            save: { [weak self] mappings in
                guard let self else {
                    return "Port forwarding could not be saved because the start menu is unavailable."
                }
                return self.savePortForwarding(mappings)
            },
            didClose: { [weak self] in
                guard let self else { return }
                self.portForwardingEditor = nil
                self.refresh()
            }
        )
        portForwardingEditor = editor
        editor.beginSheet(for: window)
    }

    private func beginResourceConfiguration() {
        guard !controlsBusy, !state.resetInProgress, !state.permissionRequestInFlight,
              resourceEditor == nil, window.attachedSheet == nil else { return }
        let editor = VMResourceEditor(
            resources: resources(),
            limits: resourceLimits,
            minimumDiskGiB: minimumDiskGiB(),
            save: { [weak self] resources in self?.saveResources(resources) },
            didClose: { [weak self] in
                self?.resourceEditor = nil
                self?.refresh()
            }
        )
        resourceEditor = editor
        editor.beginSheet(for: window)
    }

    func changeImmersiveMode(_ isEnabled: Bool) {
        guard !controlsBusy, !state.resetInProgress else { return }
        setImmersiveMode(isEnabled)
        state.immersive = isEnabled
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: StartMenuPresentation.immersiveDetail(isEnabled: isEnabled),
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    func changeNotchMode(_ isEnabled: Bool) {
        guard !controlsBusy, !state.resetInProgress else { return }
        setUsesNotch(isEnabled)
        state.usesNotch = isEnabled
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: StartMenuPresentation.notchDetail(isEnabled: isEnabled),
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    private func confirmReset() {
        guard canResetStorage,
              !prelaunchControlsLocked,
              !state.resetInProgress,
              !state.permissionRequestInFlight,
              resetConfirmationPrompt == nil else { return }
        let estimate = storageSpaceEstimate()
        var detail = "This permanently erases everything in this Omarchy virtual machine, including apps, files, accounts, and settings. This cannot be undone or recovered."
        // With a chosen data folder there can be more than one workspace on the
        // Mac, so say which one is about to be erased.
        let location = storageLocationStatus()
        if !location.isDefault, location.problem != nil {
            // The chosen folder cannot be reached, so which VM a reset would
            // erase is exactly what is in doubt. Hand straight to the
            // controller, which owns the preference and can explain and offer
            // to switch, rather than asking the user to confirm erasing a
            // workspace we would only be guessing the identity of.
            state.resetPhase = .checking
            state.resetInProgress = true
            refresh()
            resetStorage()
            return
        }
        if !location.isDefault, let displayPath = location.displayPath {
            let volume = location.volumeName.map { "\($0), " } ?? ""
            detail += " The VM being erased is the one stored at \(volume)\(displayPath)."
        }
        if let estimate {
            detail += " Resetting may free up to \(estimate) of disk space."
        }
        let prompt = VMDestructiveConfirmationPrompt(detail: detail)
        resetConfirmationPrompt = prompt
        prompt.present(for: window) { [weak self, weak prompt] confirmed in
            guard let self,
                  let prompt,
                  resetConfirmationPrompt === prompt else { return }
            resetConfirmationPrompt = nil
            guard confirmed else { return }
            pendingResetSpaceEstimate = estimate
            state.resetPhase = .checking
            state.resetInProgress = true
            refresh()
            resetStorage()
        }
    }

    func changeStartAutomatically(_ enabled: Bool) {
        guard !controlsBusy, !state.resetInProgress else { return }
        if enabled {
            // Keep the preference off until the user confirms.
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Skip the launcher"
            alert.informativeText = """
                If this setting is on, Omarchy will start automatically with your current settings whenever you open Try Omarchy.

                To see the launcher again, hold Option while opening the app, or inside Omarchy, open the Omarchy menu and choose Setup → Try Omarchy Settings.
                """
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            state.automaticStartupConfirmationInProgress = true
            let confirmed = confirmAutomaticStartup(alert) == .alertFirstButtonReturn
            state.automaticStartupConfirmationInProgress = false
            guard confirmed, !controlsBusy, !state.resetInProgress else {
                state.startAutomatically = startAutomatically()
                return
            }
        }
        if let error = setStartAutomatically(enabled) {
            state.startAutomatically = startAutomatically()
            let alert = NSAlert()
            alert.messageText = "Skip launcher couldn’t be saved"
            alert.informativeText = error
            presentStartupSaveError(alert, window)
        } else {
            state.startAutomatically = enabled
        }
    }

    @objc func launchOmarchy() {
        guard !prelaunchControlsLocked,
              !state.resetInProgress,
              !state.permissionRequestInFlight else { return }
        state.launchPhase = .checking
        state.launchDownload = nil
        state.launchInProgress = true
        refresh()
        launch()
    }
}
