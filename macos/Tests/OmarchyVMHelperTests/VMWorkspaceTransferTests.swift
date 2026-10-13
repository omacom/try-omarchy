import Darwin
import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("VM workspace relocation", .serialized)
struct VMWorkspaceTransferTests {
    private struct Fixture {
        let root: URL
        let source: URL
        let destination: URL
        let disk: URL
        let identity = String(repeating: "a", count: 64)

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("vm-transfer-\(UUID().uuidString)").resolvingSymlinksInPath()
            source = root.appendingPathComponent("original")
            destination = root.appendingPathComponent("destination")
            disk = source.appendingPathComponent("disks/current/rootfs.ext4")
            for relative in ["original", "destination", "original/boot", "original/boot/\(identity)", "original/disks", "original/disks/current", "original/locks"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(relative), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            try write(StorageLocationPolicy.rootMarkerContent + "\n", to: source.appendingPathComponent(StorageLocationPolicy.rootMarkerName))
            try write("", to: source.appendingPathComponent("locks/current.lock"))
            try write("{\"bundleIdentity\":\"\(identity)\",\"kind\":\"omarchy-qemu-persistent-disk\",\"schemaVersion\":2,\"sourceRootfs\":{\"bytes\":4096,\"sha256\":\"\(identity)\"}}\n", to: source.appendingPathComponent("disks/current/metadata.json"))
            try write("personal VM data", to: disk)
            let handle = try FileHandle(forWritingTo: disk)
            try handle.truncate(atOffset: 64 * 1024 * 1024)
            try handle.close()
            for name in ["kernel", "initramfs", "command-line", "metadata.json"] {
                try write("paired \(name)", to: source.appendingPathComponent("boot/\(identity)/\(name)"))
            }
            try write("saved startup settings", to: source.appendingPathComponent("launcher-settings.json"))
        }

        func write(_ contents: String, to url: URL) throws {
            try Data(contents.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func expectOriginalAndEmptyDestination() throws {
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
            #expect(try !FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".omarchy-vm-copy-") })
            try VMWorkspaceTransfer.requireExistingVM(source.path)
        }
    }

    @Test("Relocation preserves the disk, boot pair, and settings and keeps the original")
    func success() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let digest = try StorageIO.sha256(path: fixture.disk.path)
        #expect(try VMWorkspaceTransfer.copy(from: fixture.source.path, to: fixture.destination.path) == fixture.destination.path)
        try VMWorkspaceTransfer.requireExistingVM(fixture.destination.path)
        #expect(try StorageIO.sha256(path: fixture.disk.path) == digest)
        #expect(try StorageIO.sha256(path: fixture.destination.appendingPathComponent("disks/current/rootfs.ext4").path) == digest)
        for relative in ["boot/\(fixture.identity)/kernel", "boot/\(fixture.identity)/initramfs", "boot/\(fixture.identity)/command-line", "boot/\(fixture.identity)/metadata.json", "launcher-settings.json"] {
            #expect(try Data(contentsOf: fixture.source.appendingPathComponent(relative)) == Data(contentsOf: fixture.destination.appendingPathComponent(relative)))
        }
        try fixture.write("new copy", to: fixture.destination.appendingPathComponent("disks/current/rootfs.ext4"))
        #expect(try StorageIO.sha256(path: fixture.disk.path) == digest)
    }

    @Test("Copy errors and corrupted copies leave the source intact and destination empty", arguments: [false, true])
    func failedCopy(corrupt: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let digest = try StorageIO.sha256(path: fixture.disk.path)
        #expect(throws: (any Error).self) {
            try VMWorkspaceTransfer.copy(from: fixture.source.path, to: fixture.destination.path, copyFile: { source, destination in
                if corrupt { try fixture.write("corrupted", to: URL(fileURLWithPath: destination)) }
                else { throw HelperError.io("simulated copy failure") }
            })
        }
        #expect(try StorageIO.sha256(path: fixture.disk.path) == digest)
        try fixture.expectOriginalAndEmptyDestination()
    }

    @Test("An occupied destination is never replaced, even with a valid VM marker")
    func occupied() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("keep this file", to: fixture.destination.appendingPathComponent("personal.txt"))
        #expect(throws: (any Error).self) { try VMWorkspaceTransfer.copy(from: fixture.source.path, to: fixture.destination.path) }
        #expect(try String(contentsOf: fixture.destination.appendingPathComponent("personal.txt"), encoding: .utf8) == "keep this file")
        try fixture.write(StorageLocationPolicy.rootMarkerContent, to: fixture.destination.appendingPathComponent(StorageLocationPolicy.rootMarkerName))
        #expect(throws: (any Error).self) { try VMWorkspaceTransfer.copy(from: fixture.source.path, to: fixture.destination.path) }
    }

    @Test("Existing VM selection refuses empty and incomplete workspaces")
    func existingSelection() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try VMWorkspaceTransfer.requireExistingVM(fixture.source.path)
        #expect(throws: (any Error).self) { try VMWorkspaceTransfer.requireExistingVM(fixture.destination.path) }
        try FileManager.default.removeItem(at: fixture.disk)
        #expect(throws: (any Error).self) { try VMWorkspaceTransfer.requireExistingVM(fixture.source.path) }
    }

    @Test("Symlinks and hard links inside the workspace cancel without copying")
    func unsafeFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let link = fixture.source.appendingPathComponent("unsafe")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.disk)
        #expect(throws: (any Error).self) { try VMWorkspaceTransfer.copy(from: fixture.source.path, to: fixture.destination.path) }
        try FileManager.default.removeItem(at: link)
        try FileManager.default.linkItem(at: fixture.disk, to: link)
        #expect(throws: (any Error).self) { try VMWorkspaceTransfer.copy(from: fixture.source.path, to: fixture.destination.path) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
    }

    @Test("Source or destination changes during copying cancel publication", arguments: [false, true])
    func changedWorkspace(changeDestination: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var changed = false
        #expect(throws: (any Error).self) {
            try VMWorkspaceTransfer.copy(from: fixture.source.path, to: fixture.destination.path, copyFile: { source, destination in
                try VMWorkspaceTransfer.copyRegularFile(source, destination)
                if !changed {
                    changed = true
                    let folder = changeDestination ? fixture.destination : fixture.source
                    try fixture.write("new file", to: folder.appendingPathComponent("new-file"))
                }
            })
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("disks").path))
        if changeDestination { #expect(try String(contentsOf: fixture.destination.appendingPathComponent("new-file"), encoding: .utf8) == "new file") }
    }

    @Test("Cross-volume copy implementation retains sparse capacity and contents")
    func sparseCopy() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let output = fixture.destination.appendingPathComponent("disk-copy")
        try VMWorkspaceTransfer.copyRegularFile(fixture.disk.path, output.path, forceSparseCopy: true)
        #expect(try StorageIO.sha256(path: fixture.disk.path) == StorageIO.sha256(path: output.path))
        var info = stat()
        #expect(lstat(output.path, &info) == 0)
        #expect(info.st_size == 64 * 1024 * 1024)
        #expect(info.st_blocks * 512 < info.st_size / 2)
    }

    @Test("Copying and hashing keep the launcher lock held throughout the transaction")
    func lockRemainsHeld() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var checked = false
        _ = try VMWorkspaceTransfer.copy(from: fixture.source.path, to: fixture.destination.path, copyFile: { source, destination in
            if source.hasSuffix("rootfs.ext4") {
                let contender = Process()
                contender.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
                contender.arguments = ["-k", "-t", "0", fixture.source.appendingPathComponent("locks/current.lock").path, "/usr/bin/true"]
                contender.standardError = FileHandle.nullDevice
                try contender.run()
                contender.waitUntilExit()
                #expect(contender.terminationStatus != 0)
                checked = true
            }
            try VMWorkspaceTransfer.copyRegularFile(source, destination)
        })
        #expect(checked)
    }

    @Test("Self and nested destinations are refused")
    func overlappingLocations() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let nested = fixture.source.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try VMWorkspaceTransfer.copy(from: fixture.source.path, to: fixture.source.path) }
        #expect(throws: (any Error).self) { try VMWorkspaceTransfer.copy(from: fixture.source.path, to: nested.path) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: nested.path).isEmpty)
    }

    @Test("Insufficient space cancels before creating staging files")
    func insufficientSpace() throws {
        struct FullVolume: VolumeProbing {
            func capabilities(at url: URL) throws -> VolumeCapabilities {
                VolumeCapabilities(typeName: "apfs", volumeName: "Full drive", supportsCloning: true,
                    supportsSparseFiles: true, isLocal: true, isInternal: true, availableBytes: 1)
            }
        }
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(throws: (any Error).self) { try VMWorkspaceTransfer.copy(from: fixture.source.path, to: fixture.destination.path, probe: FullVolume()) }
        try fixture.expectOriginalAndEmptyDestination()
    }

    @Test("The launcher's POSIX lock blocks relocation while the VM is open")
    func runningVM() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        process.arguments = ["-k", "-t", "0", fixture.source.appendingPathComponent("locks/current.lock").path, "/bin/sh", "-c", "printf ready; exec /bin/sleep 30"]
        let readiness = Pipe()
        process.standardOutput = readiness
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        #expect(readiness.fileHandleForReading.readData(ofLength: 5) == Data("ready".utf8))
        #expect(throws: (any Error).self) { try VMWorkspaceTransfer.copy(from: fixture.source.path, to: fixture.destination.path) }
        try fixture.expectOriginalAndEmptyDestination()
    }
}
