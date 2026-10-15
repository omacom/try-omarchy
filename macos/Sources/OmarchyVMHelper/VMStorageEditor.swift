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
    private let delete: Delete
    private let confirmation: ((URL) -> Bool)?
    private(set) var deletionPrompt: VMDestructiveConfirmationPrompt?
    private var deletedRoot: String?
    private var confirmingDeletion = false
    private(set) var deleting = false
    private var busy: Bool { moving || deleting || confirmingDeletion }
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
    private var deleteButton: NSButton!
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
        delete: @escaping Delete = { _, _, completion in completion("VM deletion is unavailable.") },
        confirmDeletion: ((URL) -> Bool)? = nil,
        didClose: @escaping () -> Void
    ) {
        self.selectedRoot = selectedRoot
        self.isDefault = isDefault
        self.validate = validate
        self.select = select
        self.useDefault = useDefault
        self.move = move
        self.delete = delete
        confirmation = confirmDeletion
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
        } else if let root, deletedRoot == root.path, !FileManager.default.fileExists(atPath: root.path) {
            selectionLabel.stringValue = "The selected VM was moved to Trash. Choose another VM or an empty folder."
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
        deleteButton.isEnabled = !busy && hasVM
        defaultButton.isEnabled = !busy && !isDefault()
        doneButton.isEnabled = !busy
        doneButton.keyEquivalent = busy ? "" : "\r"
    }

    private func showStatus(_ text: String, error: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = error ? .systemRed : OmarchyStartMenuTheme.foreground
        NSAccessibility.post(element: statusLabel, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    private func chooseFolder(_ choice: Choice, source: URL?) -> URL? {
        if let picker { return picker(choice, source) }
        let panel = NSOpenPanel()
        switch choice {
        case .existing:
            panel.title = "Switch to another VM"
            panel.message = "Choose an existing VM's complete folder, containing its shell folder. This changes which VM the app launches. Files stay where they are."
            panel.prompt = "Select This VM"
        case .new:
            panel.title = "Choose a folder for a new VM"
            panel.message = "Choose or create an empty folder on an APFS drive. The next launch creates a separate VM here. Your current VM stays where it is."
            panel.prompt = "Select Folder"
        case .move:
            panel.title = "Move the selected VM"
            panel.message = "Source: \(source?.path ?? "")\n\nChoose a completely empty folder on an APFS drive. The VM is copied and verified, then the new folder is selected. The original remains a recovery copy."
            panel.prompt = "Copy and Switch"
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
            self.showStatus("Copied and verified. The next launch uses \(self.display(destination)). Recovery copy: \(self.display(source)). These copies now evolve independently.")
        })
    }

    @objc func deleteSelectedVM() {
        guard !busy, let source = selectedRoot() else { return }
        let identity: String
        do { identity = try VMWorkspaceTransfer.deletionIdentity(source.path) }
        catch { showStatus(error.localizedDescription, error: true); return }
        confirmingDeletion = true
        refreshSelection()
        if let confirmation {
            finishDeletionConfirmation(confirmation(source), source: source, identity: identity)
        } else {
            let detail = "Move this entire VM folder to macOS Trash:\n\n\(source.path)\n\nIt contains this VM's apps, files, accounts, and settings. Other VM copies are kept. You can recover it from Trash until you empty Trash."
            let prompt = VMDestructiveConfirmationPrompt(detail: detail, action: .delete)
            deletionPrompt = prompt
            prompt.present(for: window) { [weak self, weak prompt] confirmed in
                guard let self, let prompt, self.deletionPrompt === prompt else { return }
                self.deletionPrompt = nil
                self.finishDeletionConfirmation(confirmed, source: source, identity: identity)
            }
        }
    }

    private func finishDeletionConfirmation(_ confirmed: Bool, source: URL, identity: String) {
        confirmingDeletion = false
        guard confirmed, selectedRoot()?.path == source.path else { refreshSelection(); return }
        deleting = true
        refreshSelection()
        showStatus("Moving the selected VM to Trash…")
        progressBar.isHidden = false
        progressBar.isIndeterminate = true
        progressBar.startAnimation(nil)
        delete(source.path, identity) { [weak self] error in
            guard let self else { return }
            self.deleting = false
            self.progressBar.stopAnimation(nil)
            self.progressBar.isHidden = true
            if error == nil { self.deletedRoot = source.path }
            self.refreshSelection()
            if let error { self.showStatus(error, error: true); return }
            self.showStatus("VM moved to Trash from \(self.display(source)). Choose another VM or an empty folder to continue. Other VM copies are kept.")
        }
    }

    func receiveProgress(_ update: VMTransferProgress) {
        guard moving else { return }
        progressBar.isHidden = false
        if let fraction = update.fraction {
            progressBar.stopAnimation(nil)
            progressBar.isIndeterminate = false
            progressBar.doubleValue = fraction * 100
            statusLabel.stringValue = "\(update.title) \(Int(fraction * 100))%\nThe original VM is kept. Please wait before closing this dialog."
        } else {
            progressBar.isIndeterminate = true
            progressBar.startAnimation(nil)
            statusLabel.stringValue = "\(update.title)\nThe original VM is kept. Please wait before closing this dialog."
        }
        statusLabel.textColor = OmarchyStartMenuTheme.foreground
    }

    @objc private func done() { dismiss() }

    private func label(_ text: String, size: CGFloat = 12, bold: Bool = false, muted: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        field.textColor = muted ? OmarchyStartMenuTheme.muted : OmarchyStartMenuTheme.foreground
        return field
    }

    private func button(_ title: String, action: Selector, id: String, primary: Bool = false, danger: Bool = false) -> NSButton {
        let control = OmarchyActionButton(title: title, style: danger ? .danger : (primary ? .primary : .secondary), target: self, action: action)
        control.identifier = NSUserInterfaceItemIdentifier("vm-storage-" + id)
        control.widthAnchor.constraint(equalToConstant: primary ? 86 : 178).isActive = true
        control.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return control
    }

    private func row(_ title: String, detail: String, control: NSView) -> NSView {
        let titleLabel = label(title, size: 14, bold: true)
        let description = label(detail, muted: true)
        let text = NSStackView(views: [titleLabel, description])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 6
        let row = NSStackView(views: [text, control])
        row.alignment = .centerY
        row.spacing = 20
        description.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        text.widthAnchor.constraint(equalToConstant: 354).isActive = true
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 82).isActive = true
        return row
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 688),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Manage virtual machines"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = OmarchyStartMenuTheme.background
        window.delegate = self
        window.setAccessibilityLabel("Manage virtual machines")

        pathLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        pathLabel.textColor = OmarchyStartMenuTheme.foreground
        pathLabel.identifier = NSUserInterfaceItemIdentifier("vm-storage-selected-path")
        selectionLabel.font = .systemFont(ofSize: 12)
        selectionLabel.textColor = OmarchyStartMenuTheme.muted
        selectionLabel.identifier = NSUserInterfaceItemIdentifier("vm-storage-selection-detail")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = OmarchyStartMenuTheme.foreground
        statusLabel.identifier = NSUserInterfaceItemIdentifier("vm-storage-status")
        statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true
        progressBar.style = .bar
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.isHidden = true
        progressBar.identifier = NSUserInterfaceItemIdentifier("vm-storage-progress")
        existingButton = button("Choose Existing VM…", action: #selector(chooseExistingVM), id: "existing")
        moveButton = button("Choose Destination…", action: #selector(moveSelectedVM), id: "move")
        newButton = button("Choose Empty Folder…", action: #selector(chooseNewVM), id: "new")
        deleteButton = button("Delete VM…", action: #selector(deleteSelectedVM), id: "delete", danger: true)
        deleteButton.hasDestructiveAction = true
        defaultButton = button("Use Default Folder", action: #selector(selectDefault), id: "default")
        doneButton = button("Done", action: #selector(done), id: "done", primary: true)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [defaultButton, spacer, doneButton])
        footer.spacing = 12
        let rows: [NSView] = [
            label("Manage VMs", size: 22, bold: true),
            label("Selected VM for next launch", size: 13, bold: true), pathLabel, selectionLabel,
            row("Switch to another VM", detail: "Choose a saved VM in another folder. This changes which VM the app will launch; files stay where they are.", control: existingButton),
            row("Move the selected VM", detail: "Copy this VM to a new folder, verify it, and switch to the copy. The original remains a recovery copy.", control: moveButton),
            row("Create a separate VM", detail: "Choose an empty folder. A new VM is created on the next launch; the selected VM is kept.", control: newButton),
            row("Delete the selected VM", detail: "Move this VM folder to macOS Trash. Other VM copies are kept. You can recover it until Trash is emptied.", control: deleteButton),
            statusLabel, progressBar, footer
        ]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = OmarchyStartMenuTheme.background.cgColor
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 36),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
        for view in rows { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
}
