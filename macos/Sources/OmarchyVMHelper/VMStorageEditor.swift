import AppKit

/// Choices apply to the next launch. Moving stays in this sheet until copying,
/// verification, and the preference switch have actually completed.
@MainActor
final class VMStorageEditor: NSObject, NSWindowDelegate {
    enum Choice { case existing, new, move }
    typealias Move = (String, String, @escaping (VMTransferProgress) -> Void, @escaping (String?) -> Void) -> Void

    typealias Delete = (String, String, @escaping (String?) -> Void) -> Void

    private let selectedRoot: () -> URL?
    private let isDefault: () -> Bool
    private let validate: (String) -> String?
    private let select: (String) -> String?
    private let useDefault: () -> Void
    private let move: Move
    private let discardPrevious: Delete
    private let moveConfirmation: ((URL, URL) -> Bool)?
    private var confirming = false
    private(set) var deleting = false
    private var busy: Bool { moving || deleting || confirming }
    private let closeHandler: () -> Void
    private let picker: ((Choice, URL?) -> URL?)?
    private var closed = false
    private(set) var moving = false
    private(set) var window: NSWindow!
    private let pathLabel = NSTextField(wrappingLabelWithString: "")
    private let selectionLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "Your VM starts only when you return to the launcher and press Launch.")
    private let progressBar = NSProgressIndicator()
    private var existingButton: NSButton!
    private var moveButton: NSButton!
    private var newButton: NSButton!
    private var defaultButton: NSButton!
    private var doneButton: NSButton!

    init(
        selectedRoot: @escaping () -> URL?,
        isDefault: @escaping () -> Bool,
        validate: @escaping (String) -> String?,
        select: @escaping (String) -> String?,
        useDefault: @escaping () -> Void,
        move: @escaping Move,
        chooseFolder: ((Choice, URL?) -> URL?)? = nil,
        discardPrevious: @escaping Delete = { _, _, completion in completion("VM deletion is unavailable.") },
        confirmMove: ((URL, URL) -> Bool)? = nil,
        didClose: @escaping () -> Void
    ) {
        self.selectedRoot = selectedRoot
        self.isDefault = isDefault
        self.validate = validate
        self.select = select
        self.useDefault = useDefault
        self.move = move
        self.discardPrevious = discardPrevious
        moveConfirmation = confirmMove
        picker = chooseFolder
        closeHandler = didClose
        super.init()
        buildWindow()
        refreshSelection()
    }

    func beginSheet(for parent: NSWindow) {
        parent.beginSheet(window)
        window.makeFirstResponder(doneButton)
    }

    func dismiss() {
        guard !closed, !busy else { return }
        closed = true
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
        closeHandler()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }

    private func display(_ root: URL) -> String {
        StorageLocationPolicy.displayPath(root.path, homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    private func refreshSelection() {
        let root = selectedRoot()
        pathLabel.stringValue = root.map(display) ?? "No folder selected"
        let hasVM = root.map { QEMUGPUStorageSpaceEstimate.hasRecordedPersistentDisk(stateRoot: $0.path) } ?? false
        let unsafeDisk = !hasVM && root.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("shell/disk.img").path)
        } ?? false
        if hasVM {
            selectionLabel.stringValue = "Your next launch will boot the VM in this folder."
        } else if let root, !isDefault(), !FileManager.default.fileExists(atPath: root.path) {
            selectionLabel.stringValue = "This folder is unavailable. Reconnect its drive or choose another VM."
        } else if unsafeDisk {
            selectionLabel.stringValue = "A saved VM is present but cannot be opened safely. Choose another VM or repair this folder."
        } else {
            selectionLabel.stringValue = "No saved VM in this folder. Your next launch will create a new one here."
        }
        existingButton.isEnabled = !busy
        newButton.isEnabled = !busy
        moveButton.isEnabled = !busy && hasVM
        defaultButton.isEnabled = !busy && !isDefault()
        doneButton.isEnabled = !busy
        doneButton.keyEquivalent = busy ? "" : "\r"
    }

    private func showStatus(_ text: String, error: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = error ? .systemRed : .labelColor
        NSAccessibility.post(element: statusLabel, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    private func chooseFolder(_ choice: Choice, source: URL?) -> URL? {
        if let picker { return picker(choice, source) }
        let panel = NSOpenPanel()
        switch choice {
        case .existing: panel.prompt = "Select This VM"
        case .new: panel.prompt = "Select Folder"
        case .move: panel.prompt = "Move Here"
        }
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    @objc func chooseExistingVM() { changeSelection(.existing) }
    @objc func chooseNewVM() { changeSelection(.new) }

    private func changeSelection(_ choice: Choice) {
        guard !busy, let destination = chooseFolder(choice, source: selectedRoot()) else { return }
        if let error = validate(destination.path) { showStatus(error, error: true); return }
        do {
            if choice == .existing {
                try VMWorkspaceTransfer.requireExistingVM(destination.path)
            } else if try !FileManager.default.contentsOfDirectory(atPath: destination.path).allSatisfy({ [".DS_Store", ".localized", "Icon\r"].contains($0) }) {
                throw HelperError.io("Choose an empty folder for a new VM. To select a saved VM, use Choose Existing VM.")
            }
        } catch { showStatus(error.localizedDescription, error: true); return }
        if let error = select(destination.path) { showStatus(error, error: true); return }
        refreshSelection()
        showStatus(choice == .existing
            ? "VM selected. The next launch uses \(display(destination)). Your previous VM remains in its original folder."
            : "New VM folder selected. A fresh VM will be created when you press Launch. Your previous VM is kept.")
    }

    @objc func selectDefault() {
        guard !busy else { return }
        useDefault()
        refreshSelection()
        showStatus("Default folder selected for the next launch. Your previously selected VM stays where it is.")
    }

    @objc func moveSelectedVM() {
        guard !busy, let source = selectedRoot() else { return }
        do { try VMWorkspaceTransfer.requireExistingVM(source.path) }
        catch { showStatus(error.localizedDescription, error: true); return }
        guard let destination = chooseFolder(.move, source: source) else { return }
        if let moveConfirmation {
            if moveConfirmation(source, destination) { beginMove(source, to: destination) }
            return
        }
        // Moving always retires the original to Trash, so say so before
        // anything is copied.
        let alert = NSAlert()
        alert.messageText = "Move this VM?"
        alert.informativeText = "Omarchy copies your VM to \(display(destination)) and verifies it, then moves the original at \(display(source)) to Trash. You can recover it until you empty Trash."
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        confirming = true
        refreshSelection()
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            confirming = false
            refreshSelection()
            guard response == .alertFirstButtonReturn else { return }
            beginMove(source, to: destination)
        }
    }

    private func beginMove(_ source: URL, to destination: URL) {
        moving = true
        refreshSelection()
        receiveProgress(VMTransferProgress(phase: .checking))
        move(source.path, destination.path, { [weak self] update in
            self?.receiveProgress(update)
        }, { [weak self] error in
            guard let self else { return }
            self.moving = false
            self.progressBar.stopAnimation(nil)
            self.progressBar.isHidden = true
            self.refreshSelection()
            if let error { self.showStatus(error, error: true); return }
            guard let identity = try? VMWorkspaceTransfer.deletionIdentity(source.path) else {
                self.showStatus("Moved to \(self.display(destination)), but the previous copy could not be identified, so it stays at \(self.display(source)).", error: true)
                return
            }
            self.discardPreviousCopy(source, identity: identity, movedTo: destination)
        })
    }

    private func discardPreviousCopy(_ source: URL, identity: String, movedTo destination: URL) {
        deleting = true
        refreshSelection()
        showStatus("Moving the previous copy to Trash…")
        progressBar.isHidden = false
        progressBar.isIndeterminate = true
        progressBar.startAnimation(nil)
        discardPrevious(source.path, identity) { [weak self] error in
            guard let self else { return }
            deleting = false
            progressBar.stopAnimation(nil)
            progressBar.isHidden = true
            refreshSelection()
            if let error {
                showStatus("Moved to \(display(destination)), but the previous copy stays at \(display(source)): \(error)", error: true)
                return
            }
            showStatus("Moved and verified. The next launch uses \(display(destination)). The previous copy is in Trash.")
        }
    }

    func receiveProgress(_ update: VMTransferProgress) {
        guard moving else { return }
        progressBar.isHidden = false
        if let fraction = update.fraction {
            progressBar.stopAnimation(nil)
            progressBar.isIndeterminate = false
            progressBar.doubleValue = fraction * 100
            statusLabel.stringValue = "\(update.title) \(Int(fraction * 100))%\nThe original stays until the copy is verified. Please wait before closing this dialog."
        } else {
            progressBar.isIndeterminate = true
            progressBar.startAnimation(nil)
            statusLabel.stringValue = "\(update.title)\nThe original stays until the copy is verified. Please wait before closing this dialog."
        }
        statusLabel.textColor = .labelColor
    }

    @objc private func done() { dismiss() }

    private func button(_ title: String, action: Selector, id: String) -> NSButton {
        let control = NativeSheetChrome.button(title, target: self, action: action)
        control.identifier = NSUserInterfaceItemIdentifier("vm-storage-" + id)
        return control
    }

    private func buildWindow() {
        let width: CGFloat = 600
        window = NativeSheetChrome.window(title: "Manage virtual machines", width: width)
        window.delegate = self

        pathLabel.identifier = NSUserInterfaceItemIdentifier("vm-storage-selected-path")
        pathLabel.isSelectable = true
        selectionLabel.identifier = NSUserInterfaceItemIdentifier("vm-storage-selection-detail")
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .labelColor
        statusLabel.identifier = NSUserInterfaceItemIdentifier("vm-storage-status")
        progressBar.style = .bar
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.isHidden = true
        progressBar.identifier = NSUserInterfaceItemIdentifier("vm-storage-progress")
        existingButton = button("Choose Existing VM…", action: #selector(chooseExistingVM), id: "existing")
        moveButton = button("Choose Destination…", action: #selector(moveSelectedVM), id: "move")
        newButton = button("Choose Empty Folder…", action: #selector(chooseNewVM), id: "new")
        defaultButton = button("Use Default Folder", action: #selector(selectDefault), id: "default")
        doneButton = button("Done", action: #selector(done), id: "done")

        let heading = NativeSheetChrome.header(
            symbol: "externaldrive.fill", color: .systemGray, title: "Manage VMs",
            subtitle: "Choices apply to the next launch."
        )
        let selected = NativeSheetChrome.group([
            NativeSheetChrome.row(title: pathLabel, detail: selectionLabel),
        ])
        let choices = NativeSheetChrome.group([
            NativeSheetChrome.row(
                title: "Switch to another VM",
                detail: "Choose a saved VM in another folder. This changes which VM the app will launch; files stay where they are.",
                control: existingButton
            ),
            NativeSheetChrome.row(
                title: "Move the selected VM",
                detail: "Copy this VM to a new folder, verify it, and switch to the copy. The original moves to Trash.",
                control: moveButton
            ),
            NativeSheetChrome.row(
                title: "Create a separate VM",
                detail: "Choose an empty folder. A new VM is created on the next launch; the selected VM is kept.",
                control: newButton
            ),
        ])
        progressBar.controlSize = .small
        // Keep the bar's space reserved so the sheet does not jump while copying.
        let statusStack = NSStackView()
        statusStack.detachesHiddenViews = false
        statusStack.orientation = .vertical
        statusStack.alignment = .leading
        statusStack.spacing = 6
        statusStack.addArrangedSubview(statusLabel)
        statusStack.addArrangedSubview(progressBar)
        statusLabel.widthAnchor.constraint(equalTo: statusStack.widthAnchor).isActive = true
        progressBar.widthAnchor.constraint(equalTo: statusStack.widthAnchor).isActive = true
        statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        let status = NativeSheetChrome.inset(statusStack)
        let footer = NativeSheetChrome.actions(leading: [defaultButton], trailing: [doneButton])

        let stack = NSStackView(views: [
            heading,
            NativeSheetChrome.sectionTitle("Selected VM for next launch"), selected,
            choices, status, footer,
        ])
        stack.spacing = 8
        stack.setCustomSpacing(16, after: heading)
        stack.setCustomSpacing(6, after: stack.arrangedSubviews[1])
        stack.setCustomSpacing(16, after: selected)
        stack.setCustomSpacing(10, after: choices)
        stack.setCustomSpacing(12, after: status)
        NativeSheetChrome.install(stack, in: window, width: width)
    }
}
