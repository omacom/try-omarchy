import Foundation
import Testing
@testable import OmarchyVMHelper

/// The picker and the launcher must agree on what an Omarchy workspace looks
/// like. They are written in different languages and neither can import the
/// other's constants, so the agreement is pinned here: if one side's marker
/// name or token changes without the other, these fail rather than shipping a
/// picker that accepts folders the launcher then refuses.
@Suite("Storage location native contract")
struct StorageLocationContractTests {
    @Test("the marker filename and token match the ones the launcher writes")
    func markerFilenameAndToken() throws {
        let launcher = try source(named: "run-qemu-gpu.sh")
        #expect(launcher.contains("root_marker=\"$state_root/\(StorageLocationPolicy.rootMarkerName)\""))
        #expect(launcher.contains("printf '%s\\n' \(StorageLocationPolicy.rootMarkerContent) >\"$root_marker\""))
        #expect(launcher.contains("$(<\"$1\") == \(StorageLocationPolicy.rootMarkerContent) ]]"))
    }

    @Test("the default state root the launcher falls back to is still the documented one")
    func defaultStateRoot() throws {
        let launcher = try source(named: "run-qemu-gpu.sh")
        #expect(launcher.contains(
            "state_root=${\(StorageLocationPolicy.environmentKey):-\"$HOME/Library/Application Support/Try Omarchy/VM/v1\"}"
        ))
    }

    @Test("the launcher refuses the same broad storage roots as the picker")
    func unsafeRoots() throws {
        let launcher = try source(named: "run-qemu-gpu.sh")
        let roots = StorageLocationPolicy.unsafeRoots.subtracting(["/"]).sorted().joined(separator: " | ")
        #expect(launcher.contains("  '' | \(roots)) fail \"refusing an unsafe VM storage location"))
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
