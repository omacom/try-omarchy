import AppKit
import Testing
@testable import OmarchyVMHelper

@Suite("USB device picker", .serialized)
@MainActor
struct USBDeviceEditorTests {
    private let first = USBDeviceIdentity(
        vendorId: 1, productId: 2, name: "Board", locationId: 0x0110_0000
    )
    private let twin = USBDeviceIdentity(
        vendorId: 1, productId: 2, name: "Board", locationId: 0x0210_0000
    )
    private let other = USBDeviceIdentity(
        vendorId: 3, productId: 4, name: "Other board", locationId: 0x0310_0000
    )

    @Test("identical port numbers on different buses preserve all device choices")
    func distinctBuses() throws {
        _ = NSApplication.shared
        let editor = makeEditor(connected: [first, twin, other])
        let popup = try popup(in: editor)
        #expect(popup.numberOfItems == 3)
        #expect(Set(popup.itemTitles).count == 3)
        #expect(popup.itemTitles[0].contains("bus 1, port 1"))
        #expect(popup.itemTitles[1].contains("bus 2, port 1"))
        for (index, device) in [first, twin, other].enumerated() {
            popup.selectItem(at: index)
            #expect(editor.selectedDevice == device)
        }
    }

    @Test("even duplicate labels cannot shift another item's saved identity")
    func duplicateLabels() throws {
        _ = NSApplication.shared
        var unlocated = first
        unlocated.locationId = nil
        let editor = makeEditor(connected: [unlocated, unlocated, other])
        let popup = try popup(in: editor)
        #expect(popup.numberOfItems == 3)
        popup.selectItem(at: 2)
        #expect(editor.selectedDevice == other)
    }

    @Test("an absent saved device remains selected even when its twin is connected")
    func absentSavedDevice() throws {
        _ = NSApplication.shared
        let editor = makeEditor(saved: first, connected: [twin, other])
        let popup = try popup(in: editor)
        #expect(popup.numberOfItems == 3)
        #expect(popup.selectedItem?.title.hasPrefix("Not connected:") == true)
        #expect(editor.selectedDevice == first)
    }

    @Test("a connected saved twin is selected by its physical location")
    func savedTwin() throws {
        _ = NSApplication.shared
        let editor = makeEditor(saved: twin, connected: [first, twin, other])
        #expect(editor.selectedDevice == twin)
    }

    @Test("a new picker selects the first device and an empty picker has no selection")
    func initialSelection() {
        _ = NSApplication.shared
        #expect(makeEditor(connected: [first, other]).selectedDevice == first)
        #expect(makeEditor(connected: []).selectedDevice == nil)
    }

    private func makeEditor(saved: USBDeviceIdentity? = nil, connected: [USBDeviceIdentity]) -> USBDeviceEditor {
        USBDeviceEditor(
            preference: USBDevicePreference(device: saved, isEnabled: saved != nil),
            connected: connected, save: { _ in }, didClose: {}
        )
    }

    private func popup(in editor: USBDeviceEditor) throws -> NSPopUpButton {
        try #require(Mirror(reflecting: editor).children.first { $0.label == "devices" }?.value as? NSPopUpButton)
    }
}
