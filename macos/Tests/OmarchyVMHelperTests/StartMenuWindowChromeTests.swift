import AppKit
import Testing
@testable import OmarchyVMHelper

@Suite("Start menu window chrome", .serialized)
@MainActor
struct StartMenuWindowChromeTests {
    @Test("the launcher window uses native chrome and the system appearance")
    func windowChrome() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 760),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        StartMenuWindowChrome.apply(to: window)

        #expect(window.title == "Try Omarchy")
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.appearance == nil)
        #expect(window.contentMinSize == StartMenuWindowChrome.minimumContentSize)
        #expect(!window.isReleasedWhenClosed)
        window.close()

        let editor = PortForwardingEditor(mappings: [], save: { _ in nil })
        #expect(editor.window.title == "Port Forwarding")
        #expect(editor.window.titleVisibility == .hidden)
        editor.dismiss()
    }
}
