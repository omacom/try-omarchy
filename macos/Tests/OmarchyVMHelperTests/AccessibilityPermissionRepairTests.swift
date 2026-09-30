import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Accessibility permission repair", .serialized)
struct AccessibilityPermissionRepairTests {
    @Test("a successful scoped TCC reset is reported")
    func successfulReset() {
        #expect(
            AccessibilityPermissionRepair.resetStaleEntry(
                bundleIdentifier: "dev.tryomarchy.native",
                tccutilURL: URL(fileURLWithPath: "/usr/bin/true")
            )
        )
    }

    @Test("a failed scoped TCC reset does not masquerade as success")
    func failedReset() {
        #expect(
            !AccessibilityPermissionRepair.resetStaleEntry(
                bundleIdentifier: "dev.tryomarchy.native",
                tccutilURL: URL(fileURLWithPath: "/usr/bin/false")
            )
        )
    }

    @Test("a command-line helper without an app identity cannot reset permissions")
    func missingBundleIdentifier() {
        #expect(!AccessibilityPermissionRepair.resetStaleEntry(
            bundleIdentifier: nil,
            tccutilURL: URL(fileURLWithPath: "/usr/bin/true")
        ))
    }

    @Test("repair scopes its reset to the development or production bundle", arguments: [
        "dev.tryomarchy.native", "dev.tryomarchy.native.development"
    ])
    func scopedBundleIdentifier(identifier: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = directory.appendingPathComponent("tccutil")
        let arguments = directory.appendingPathComponent("arguments")
        try "#!/bin/bash\nprintf '%s\\n' \"$@\" > \"${0%/*}/arguments\"\n".write(
            to: probe, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: probe.path)
        #expect(AccessibilityPermissionRepair.resetStaleEntry(
            bundleIdentifier: identifier, tccutilURL: probe
        ))
        #expect(try String(contentsOf: arguments, encoding: .utf8) == "reset\nAccessibility\n\(identifier)\n")
    }
}
