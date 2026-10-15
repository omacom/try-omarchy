import Foundation
import Testing

@Suite("Mac keyboard geometry native contract")
struct MacKeyboardGeometryContractTests {
    @Test("Runner publishes helper geometry to the guest and to Cocoa")
    func runnerMapping() throws {
        let runner = try source(named: "run-qemu-gpu.sh")
        let helper = try source(named: "Sources/OmarchyVMHelper/main.swift")
        let detector = try source(named: "Sources/OmarchyVMHelper/HostKeyboardGeometry.swift")

        #expect(runner.contains("--host-keyboard-geometry"))
        #expect(runner.contains("host_options+=\" tryomarchy.keyboard=$keyboard\""))
        #expect(runner.contains("export TRYOMARCHY_KEYBOARD=$keyboard"))
        #expect(helper.contains("--host-keyboard-geometry"))
        #expect(detector.contains("kKeyboardANSI"))
        #expect(detector.contains("UnknownLayoutType"))
        #expect(!runner.contains("/usr/bin/swift"))
    }

    @Test("Cocoa swaps Grave/102nd only when TRYOMARCHY_KEYBOARD is iso")
    func cocoaIsoSwap() throws {
        let patch = try source(named: "patches/qemu-cocoa-iso-section-grave-swap.patch")

        #expect(patch.contains("strcmp(geometry, \"iso\") == 0"))
        #expect(!patch.contains("KBGetLayoutType"))
        #expect(patch.contains("return KEY_102ND;"))
        #expect(patch.contains("return KEY_GRAVE;"))
    }

    private func source(named relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let macosDirectory = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: macosDirectory.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
