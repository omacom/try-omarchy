import Darwin
import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Network identity")
struct NetworkIdentityTests {
    @Test("MAC changes wait for the VM's launcher lock")
    func persistentWorkspace() throws {
        let fixture = try IdentityFixture()
        defer { fixture.remove() }
        let mac = try fixture.operation(["ensure"])
        let access = VMNetworkIdentityAccess.forLaunch(arguments: []) { try fixture.operation($0) }
        #expect(try access.read() == mac)
        #expect(access.canReplace())

        // The launcher holds shell/lock while the VM runs.
        let descriptor = open(fixture.root.appendingPathComponent("shell/lock").path, O_RDWR)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        #expect(!access.canReplace())
        let proposed = mac == "02:11:22:33:44:55" ? "02:11:22:33:44:66" : "02:11:22:33:44:55"
        #expect(throws: (any Error).self) { try access.replace(mac, proposed) }
        #expect(try access.read() == mac)
        #expect(flock(descriptor, LOCK_UN) == 0)

        #expect(try access.replace(mac, proposed) == proposed)
        #expect(try access.read() == proposed)
        let previous = fixture.root.appendingPathComponent("network-identities/current.previous.json")
        #expect(FileManager.default.fileExists(atPath: previous.path))
    }

    @Test("Ephemeral controls never read or replace a saved persistent identity",
          arguments: [["--ephemeral"], ["--ephemeral", "/tmp/custom-guest"]])
    func ephemeralLaunch(arguments: [String]) throws {
        let fixture = try IdentityFixture()
        defer { fixture.remove() }
        let persistentMAC = try fixture.operation(["ensure"])
        let record = fixture.root.appendingPathComponent("network-identities/current.json")
        let original = try Data(contentsOf: record)
        var operations = 0
        let access = VMNetworkIdentityAccess.forLaunch(arguments: arguments) {
            operations += 1
            return try fixture.operation($0)
        }
        #expect(access.isEphemeral)
        #expect(try access.read().isEmpty)
        #expect(!access.canReplace())
        #expect(throws: (any Error).self) { try access.replace(persistentMAC, "02:11:22:33:44:55") }
        #expect(operations == 0)
        #expect(try Data(contentsOf: record) == original)
    }
}

private struct IdentityFixture {
    let directory: URL
    let root: URL
    let resources: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("network-identity-\(UUID().uuidString)")
        root = directory.appendingPathComponent("workspace")
        resources = directory.appendingPathComponent("resources")
        let shell = root.appendingPathComponent("shell")
        let scripts = resources.appendingPathComponent("scripts")
        for folder in [root, shell, scripts] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        guard FileManager.default.createFile(atPath: shell.appendingPathComponent("lock").path, contents: Data(),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw HelperError.io("Cannot create test VM lock.")
        }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("network-identity.py")
        try FileManager.default.copyItem(at: source, to: scripts.appendingPathComponent("network-identity.py"))
    }

    func operation(_ arguments: [String]) throws -> String {
        try VMNetworkIdentityAccess.operation(arguments, root: root, resources: resources)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
