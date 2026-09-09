import AppKit
import Testing
@testable import OmarchyVMHelper

@Suite("Resource editor", .serialized)
@MainActor
struct VMResourceEditorTests {
    private let limits = VMResourceLimits(hostCPUCount: 18, hostMemoryBytes: 48 << 30)

    @Test("Invalid CPU edits disable Save; correcting them saves the selected draft once")
    func validationAndSave() throws {
        _ = NSApplication.shared
        var saved: [VMResources] = []
        var closed = 0
        let editor = VMResourceEditor(
            resources: limits.defaults, limits: limits,
            save: { saved.append($0) }, didClose: { closed += 1 }
        )
        let cpu: NSTextField = try control("cpu", in: editor)
        let memory: NSPopUpButton = try control("memory", in: editor)
        let save: NSButton = try control("save", in: editor)
        cpu.stringValue = "19"
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(!save.isEnabled)
        #expect(saved.isEmpty)
        cpu.stringValue = "18"
        memory.selectItem(withTag: 12)
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(save.isEnabled)
        save.performClick(nil)
        editor.dismiss()
        #expect(saved == [VMResources(cpuCount: 18, memoryGiB: 12)])
        #expect(closed == 1)
    }

    @Test("Use Defaults changes only the draft and Cancel never publishes it")
    func defaultsAndCancel() throws {
        _ = NSApplication.shared
        var saved: [VMResources] = []
        let editor = VMResourceEditor(
            resources: VMResources(cpuCount: 18, memoryGiB: 12), limits: limits,
            save: { saved.append($0) }, didClose: {}
        )
        let defaults: NSButton = try control("defaults", in: editor)
        defaults.performClick(nil)
        let cpu: NSTextField = try control("cpu", in: editor)
        let memory: NSPopUpButton = try control("memory", in: editor)
        #expect(cpu.stringValue == "8")
        #expect(memory.selectedItem?.tag == 4)
        #expect(saved.isEmpty)
        let cancel: NSButton = try control("cancel", in: editor)
        cancel.performClick(nil)
        #expect(saved.isEmpty)
    }

    @Test("A small host retains a usable default memory choice")
    func smallHost() throws {
        _ = NSApplication.shared
        let editor = VMResourceEditor(
            resources: VMResources(cpuCount: 18, memoryGiB: 12),
            limits: VMResourceLimits(hostCPUCount: 8, hostMemoryBytes: 8 << 30),
            save: { _ in }, didClose: {}
        )
        defer { editor.dismiss() }
        let memory: NSPopUpButton = try control("memory", in: editor)
        #expect(memory.itemArray.map(\.tag) == [4])
        #expect(memory.selectedItem?.tag == 4)
        #expect(!memory.isEnabled)
        let save: NSButton = try control("save", in: editor)
        #expect(save.isEnabled)
    }

    private func control<T: NSView>(_ name: String, in editor: VMResourceEditor) throws -> T {
        func find(in view: NSView) -> T? {
            if view.identifier?.rawValue == "vm-resources-\(name)" { return view as? T }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        let content = try #require(editor.window.contentView)
        return try #require(find(in: content))
    }
}
