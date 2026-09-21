import Darwin
import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Network identity workspace selection")
struct NetworkIdentityTests {
    @Test("Development MAC operations use their own record and launcher lock")
    func developmentWorkspace() throws {
        let fixture = try IdentityFixture()
        defer { fixture.remove() }
        let releaseMAC = try fixture.operation(["ensure"])
        let releaseRecord = fixture.root.appendingPathComponent("network-identities/current.json")
        let releaseBytes = try Data(contentsOf: releaseRecord)
        let developmentMAC = try fixture.operation(["ensure"], development: true)
        let access = VMNetworkIdentityAccess.forLaunch(arguments: []) {
            try fixture.operation($0, development: true)
        }
        #expect(try access.read() == developmentMAC)
        #expect(access.canReplace())

        let descriptor = open(fixture.root.appendingPathComponent("locks/\(fixture.key).lock").path, O_RDWR)
        #expect(descriptor >= 0)
        defer { close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        #expect(!access.canReplace())
        let proposed = developmentMAC == "02:11:22:33:44:55" ? "02:11:22:33:44:66" : "02:11:22:33:44:55"
        #expect(throws: (any Error).self) { try access.replace(developmentMAC, proposed) }
        #expect(try access.read() == developmentMAC)
        #expect(flock(descriptor, LOCK_UN) == 0)

        #expect(try access.replace(developmentMAC, proposed) == proposed)
        #expect(try access.read() == proposed)
        #expect(try fixture.operation(["show"]) == releaseMAC)
        #expect(try Data(contentsOf: releaseRecord) == releaseBytes)
        #expect(!FileManager.default.fileExists(atPath:
            fixture.root.appendingPathComponent("network-identities/current.previous.json").path))
    }

    @Test("An unresolved development identity never falls back to the release VM")
    func missingDevelopmentIdentity() throws {
        let fixture = try IdentityFixture()
        defer { fixture.remove() }
        let releaseMAC = try fixture.operation(["ensure"])
        #expect(throws: (any Error).self) {
            try VMNetworkIdentityAccess.operation(["show"], root: fixture.root, resources: fixture.resources,
                environment: ["OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK": "1"], bundleIdentity: nil)
        }
        #expect(try fixture.operation(["show"]) == releaseMAC)
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
    let key = String(repeating: "a", count: 64)

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("network-identity-\(UUID().uuidString)")
        root = directory.appendingPathComponent("workspace")
        resources = directory.appendingPathComponent("resources")
        let locks = root.appendingPathComponent("locks")
        let scripts = resources.appendingPathComponent("scripts")
        for folder in [root, locks, scripts] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }
        for name in ["current", key] {
            let path = locks.appendingPathComponent("\(name).lock").path
            guard FileManager.default.createFile(atPath: path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
                throw HelperError.io("Cannot create test workspace lock.")
            }
        }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("network-identity.py")
        try FileManager.default.copyItem(at: source, to: scripts.appendingPathComponent("network-identity.py"))
    }

    func operation(_ arguments: [String], development: Bool = false) throws -> String {
        try VMNetworkIdentityAccess.operation(arguments, root: root, resources: resources,
            environment: development ? ["OMARCHY_QEMU_GPU_DEVELOPMENT_MULTI_DISK": "1"] : [:], bundleIdentity: key)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
