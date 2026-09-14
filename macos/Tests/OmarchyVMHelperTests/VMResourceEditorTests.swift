import AppKit
import Testing
@testable import OmarchyVMHelper

@Suite("Resource editor", .serialized)
@MainActor
struct VMResourceEditorTests {
    private let limits = VMResourceLimits(hostCPUCount: 18, hostMemoryBytes: 48 << 30)

    @Test("CPU choices include every available count and Save publishes the draft once")
    func cpuChoicesAndSave() throws {
        _ = NSApplication.shared
        var saved: [VMResources] = []
        var closed = 0
        let editor = VMResourceEditor(
            resources: limits.defaults, limits: limits,
            save: { saved.append($0) }, didClose: { closed += 1 }
        )
        let cpu: NSPopUpButton = try control("cpu", in: editor)
        let memory: NSPopUpButton = try control("memory", in: editor)
        let save: NSButton = try control("save", in: editor)
        #expect(cpu.itemArray.map(\.tag) == Array(4...18))
        #expect(cpu.selectedItem?.title == "8 cores · default")
        #expect(cpu.itemArray.last?.title == "18 cores · all cores")
        #expect(cpu.isEnabled)
        cpu.selectItem(withTag: 18)
        cpu.sendAction(cpu.action, to: cpu.target)
        memory.selectItem(withTag: 12)
        memory.sendAction(memory.action, to: memory.target)
        #expect(saved.isEmpty)
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
        let cpu: NSPopUpButton = try control("cpu", in: editor)
        let memory: NSPopUpButton = try control("memory", in: editor)
        #expect(cpu.selectedItem?.tag == 8)
        #expect(memory.selectedItem?.tag == 8)
        #expect(saved.isEmpty)
        let cancel: NSButton = try control("cancel", in: editor)
        cancel.performClick(nil)
        #expect(saved.isEmpty)
    }

    @Test("A saved odd core count remains selected")
    func savedOddCoreCount() throws {
        _ = NSApplication.shared
        let editor = VMResourceEditor(
            resources: VMResources(cpuCount: 7, memoryGiB: 8), limits: limits,
            save: { _ in }, didClose: {}
        )
        defer { editor.dismiss() }
        let cpu: NSPopUpButton = try control("cpu", in: editor)
        #expect(cpu.selectedItem?.tag == 7)
    }

    @Test("Small hosts mark their default and disable a single-choice menu", arguments: [4, 6, 8])
    func smallHostCPUChoices(cores: Int) throws {
        _ = NSApplication.shared
        let host = VMResourceLimits(hostCPUCount: cores, hostMemoryBytes: 8 << 30)
        let editor = VMResourceEditor(
            resources: host.defaults, limits: host, save: { _ in }, didClose: {}
        )
        defer { editor.dismiss() }
        let cpu: NSPopUpButton = try control("cpu", in: editor)
        #expect(cpu.itemArray.map(\.tag) == Array(4...cores))
        #expect(cpu.selectedItem?.title == "\(cores) cores · default")
        #expect(cpu.isEnabled == (cores > 4))
    }

    @Test("High memory is selectable and the performance note does not block Save")
    func highMemoryAdvisory() throws {
        _ = NSApplication.shared
        var saved: VMResources?
        let host = VMResourceLimits(hostCPUCount: 8, hostMemoryBytes: 16 << 30)
        let editor = VMResourceEditor(
            resources: host.defaults, limits: host,
            save: { saved = $0 }, didClose: {}
        )
        defer { editor.dismiss() }
        let memory: NSPopUpButton = try control("memory", in: editor)
        let note: NSTextField = try control("validation", in: editor)
        let save: NSButton = try control("save", in: editor)
        #expect(memory.selectedItem?.title == "8 GiB · default")
        memory.selectItem(withTag: 12)
        memory.sendAction(memory.action, to: memory.target)
        #expect(memory.selectedItem?.title == "12 GiB · may slow macOS")
        #expect(note.stringValue == "This leaves 4 GiB for macOS and may slow other apps.")
        #expect(save.isEnabled)
        memory.selectItem(withTag: 8)
        memory.sendAction(memory.action, to: memory.target)
        #expect(note.stringValue.isEmpty)
        memory.selectItem(withTag: 12)
        memory.sendAction(memory.action, to: memory.target)
        save.performClick(nil)
        #expect(saved == VMResources(cpuCount: 8, memoryGiB: 12))
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
