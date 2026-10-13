import AppKit
import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("VM management dialog", .serialized)
@MainActor
struct VMStorageEditorTests {
    private func button(_ id: String, in editor: VMStorageEditor) -> NSButton {
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.identifier?.rawValue == id { return button }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(editor.window.contentView!)!
    }
    private func text(_ id: String, in editor: VMStorageEditor) -> String {
        func find(_ view: NSView) -> NSTextField? {
            if let label = view as? NSTextField, label.identifier?.rawValue == id { return label }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(editor.window.contentView!)!.stringValue
    }
    private func savedVM() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vm-management-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("disks/current"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let identity = String(repeating: "a", count: 64)
        let files = [
            StorageLocationPolicy.rootMarkerName: StorageLocationPolicy.rootMarkerContent,
            "disks/current/rootfs.ext4": "data",
            "disks/current/metadata.json": "{\"bundleIdentity\":\"\(identity)\",\"kind\":\"omarchy-qemu-persistent-disk\",\"schemaVersion\":2,\"sourceRootfs\":{\"bytes\":4,\"sha256\":\"\(identity)\"}}"
        ]
        for (name, content) in files {
            let file = root.appendingPathComponent(name)
            try Data(content.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        return root
    }

    @Test("Copy remains open with Done and selection disabled, then reports success in the same dialog")
    func moveLifecycle() throws {
        _ = NSApplication.shared
        let original = try savedVM()
        defer { try? FileManager.default.removeItem(at: original) }
        let destination = original.deletingLastPathComponent().appendingPathComponent("new-vm")
        var selected = original
        var progress: ((VMTransferProgress) -> Void)?
        var complete: ((String?) -> Void)?
        var closed = false
        let editor = VMStorageEditor(selectedRoot: { selected }, isDefault: { false }, validate: { _ in nil },
            select: { _ in nil }, useDefault: {}, move: { source, target, onProgress, onComplete in
                #expect(source == original.path)
                #expect(target == destination.path)
                progress = onProgress
                complete = onComplete
            }, chooseFolder: { _, _ in destination }, didClose: { closed = true })
        defer { editor.dismiss() }
        editor.moveSelectedVM()
        #expect(editor.moving)
        #expect(!button("vm-storage-done", in: editor).isEnabled)
        #expect(!button("vm-storage-existing", in: editor).isEnabled)
        editor.dismiss()
        #expect(!closed)
        progress?(VMTransferProgress(phase: .verifying, completedBytes: 50, totalBytes: 100))
        #expect(text("vm-storage-status", in: editor).contains("50%"))
        selected = destination
        complete?(nil)
        #expect(!editor.moving)
        #expect(button("vm-storage-done", in: editor).isEnabled)
        #expect(text("vm-storage-selected-path", in: editor).contains("new-vm"))
        #expect(text("vm-storage-status", in: editor).contains("Recovery copy:"))
        editor.dismiss()
        #expect(closed)
    }

    @Test("A failed move preserves the selection and shows a recoverable error without closing")
    func failedMove() throws {
        let original = try savedVM()
        defer { try? FileManager.default.removeItem(at: original) }
        var closed = false
        let editor = VMStorageEditor(selectedRoot: { original }, isDefault: { false }, validate: { _ in nil },
            select: { _ in nil }, useDefault: {}, move: { _, _, _, completion in completion("Disk is open; shut down first.") },
            chooseFolder: { _, _ in original.appendingPathComponent("target") }, didClose: { closed = true })
        defer { editor.dismiss() }
        editor.moveSelectedVM()
        #expect(text("vm-storage-status", in: editor) == "Disk is open; shut down first.")
        #expect(!editor.moving)
        #expect(!closed)
        #expect(button("vm-storage-done", in: editor).isEnabled)
        #expect(text("vm-storage-selected-path", in: editor).contains(original.lastPathComponent))
    }

    @Test("Switching selects another saved VM; cancelling or rejecting a folder keeps the current one")
    func switching() throws {
        let original = try savedVM()
        let other = try savedVM()
        defer { try? FileManager.default.removeItem(at: original); try? FileManager.default.removeItem(at: other) }
        var selected = original
        var choice: URL? = nil
        var selectionCount = 0
        let editor = VMStorageEditor(selectedRoot: { selected }, isDefault: { false }, validate: { _ in nil },
            select: { path in selected = URL(fileURLWithPath: path); selectionCount += 1; return nil }, useDefault: {},
            move: { _, _, _, _ in }, chooseFolder: { _, _ in choice }, didClose: {})
        defer { editor.dismiss() }
        editor.chooseExistingVM()
        #expect(selectionCount == 0)
        choice = other
        editor.chooseExistingVM()
        #expect(selected.path == other.path)
        #expect(selectionCount == 1)
        #expect(text("vm-storage-status", in: editor).contains("previous VM remains"))
        choice = original.deletingLastPathComponent()
        editor.chooseExistingVM()
        #expect(selected.path == other.path)
        #expect(selectionCount == 1)
    }
}
