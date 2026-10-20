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
            disk = source.appendingPathComponent("shell/disk.img")
            for relative in ["original", "destination", "original/shell", "original/shell-factory"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(relative), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            try write(StorageLocationPolicy.rootMarkerContent + "\n", to: source.appendingPathComponent(StorageLocationPolicy.rootMarkerName))
            try write("", to: source.appendingPathComponent("shell/lock"))
            try write("personal VM data", to: disk)
            let handle = try FileHandle(forWritingTo: disk)
            try handle.truncate(atOffset: 64 * 1024 * 1024)
            try handle.close()
            try write("uefi variables", to: source.appendingPathComponent("shell/efi-vars.fd"))
            try write("{\"format\":1}", to: source.appendingPathComponent("shell/vm.json"))
            try write("factory copy", to: source.appendingPathComponent("shell-factory/\(identity).img"))
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

    @Test("Relocation preserves the disk, UEFI variables and settings, skips the factory copy and keeps the original")
    func success() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let digest = try StorageIO.sha256(path: fixture.disk.path)
        #expect(try VMWorkspaceTransfer.copy(from: fixture.source.path, to: fixture.destination.path) == fixture.destination.path)
        try VMWorkspaceTransfer.requireExistingVM(fixture.destination.path)
        #expect(try StorageIO.sha256(path: fixture.disk.path) == digest)
        #expect(try StorageIO.sha256(path: fixture.destination.appendingPathComponent("shell/disk.img").path) == digest)
        for relative in ["shell/efi-vars.fd", "shell/vm.json", "launcher-settings.json"] {
            #expect(try Data(contentsOf: fixture.source.appendingPathComponent(relative)) == Data(contentsOf: fixture.destination.appendingPathComponent(relative)))
        }
        #expect(FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("shell/lock").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("shell-factory").path))
        try fixture.write("new copy", to: fixture.destination.appendingPathComponent("shell/disk.img"))
        #expect(try StorageIO.sha256(path: fixture.disk.path) == digest)
    }

    @Test("Progress measures both verified copies and never reports completion before publication")
    func verificationProgress() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var updates: [VMTransferProgress] = []
        _ = try VMWorkspaceTransfer.copy(from: fixture.source.path, to: fixture.destination.path, progress: { updates.append($0) })
        #expect(updates.first?.phase == .checking)
        #expect(updates.contains { $0.phase == .copying })
        let verification = updates.filter { $0.phase == .verifying }
        #expect(verification.count > 2)
        #expect(verification.last?.fraction == 1)
        #expect(verification.last!.totalBytes >= 2 * 64 * 1024 * 1024)
        for (previous, next) in zip(verification, verification.dropFirst()) {
            #expect(next.completedBytes >= previous.completedBytes)
            #expect(next.totalBytes == previous.totalBytes)
        }
        #expect(updates.last?.phase == .finishing)
        try VMWorkspaceTransfer.requireExistingVM(fixture.destination.path)
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
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("shell").path))
        if changeDestination { #expect(try String(contentsOf: fixture.destination.appendingPathComponent("new-file"), encoding: .utf8) == "new file") }
    }

    @Test("Native picker metadata changes do not prevent copying into the same empty folder")
    func pickerMetadataChanges() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var changed = false
        _ = try VMWorkspaceTransfer.copy(from: fixture.source.path, to: fixture.destination.path, copyFile: { source, destination in
            try VMWorkspaceTransfer.copyRegularFile(source, destination)
            if !changed {
                changed = true
                try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: fixture.destination.path)
            }
        })
        try VMWorkspaceTransfer.requireExistingVM(fixture.destination.path)
    }

    @Test("An empty replacement destination is refused even when its path is unchanged")
    func replacedDestination() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var replaced = false
        #expect(throws: (any Error).self) {
            try VMWorkspaceTransfer.copy(from: fixture.source.path, to: fixture.destination.path, copyFile: { source, destination in
                try VMWorkspaceTransfer.copyRegularFile(source, destination)
                if !replaced {
                    replaced = true
                    try FileManager.default.moveItem(at: fixture.destination, to: fixture.root.appendingPathComponent("old-destination"))
                    try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: false)
                }
            })
        }
        try fixture.expectOriginalAndEmptyDestination()
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
            if source.hasSuffix("disk.img") {
                let contender = Process()
                contender.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
                contender.arguments = ["-k", "-t", "0", fixture.source.appendingPathComponent("shell/lock").path, "/usr/bin/true"]
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
        process.arguments = ["-k", "-t", "0", fixture.source.appendingPathComponent("shell/lock").path, "/bin/sh", "-c", "printf ready; exec /bin/sleep 30"]
        let readiness = Pipe()
        process.standardOutput = readiness
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        #expect(readiness.fileHandleForReading.readData(ofLength: 5) == Data("ready".utf8))
        #expect(throws: (any Error).self) { try VMWorkspaceTransfer.copy(from: fixture.source.path, to: fixture.destination.path) }
        try fixture.expectOriginalAndEmptyDestination()
    }
    @Test("Deletion recycles exactly the confirmed workspace with launcher locks held")
    func recycleSelectedWorkspace() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let identity = try VMWorkspaceTransfer.deletionIdentity(fixture.source.path)
        let recovery = fixture.root.appendingPathComponent("recovery")
        try VMWorkspaceTransfer.trash(fixture.source.path, expectedIdentity: identity) { url in
            #expect(url.path == fixture.source.path)
            let contender = Process()
            contender.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
            contender.arguments = ["-k", "-t", "0", fixture.source.appendingPathComponent("shell/lock").path, "/usr/bin/true"]
            contender.standardError = FileHandle.nullDevice
            try contender.run()
            contender.waitUntilExit()
            #expect(contender.terminationStatus != 0)
            try FileManager.default.moveItem(at: url, to: recovery)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.source.path))
        try VMWorkspaceTransfer.requireExistingVM(recovery.path)
        #expect(try String(contentsOf: recovery.appendingPathComponent("launcher-settings.json"), encoding: .utf8) == "saved startup settings")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.path).isEmpty)
    }

    @Test("Deletion refuses a changed confirmed disk or an unsafe workspace", arguments: [false, true])
    func refuseUnsafeDeletion(unsafe: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let identity = try VMWorkspaceTransfer.deletionIdentity(fixture.source.path)
        if unsafe {
            try FileManager.default.createSymbolicLink(at: fixture.source.appendingPathComponent("unsafe"), withDestinationURL: fixture.disk)
        } else {
            let handle = try FileHandle(forWritingTo: fixture.disk)
            try handle.write(contentsOf: Data("changed after confirmation".utf8))
            try handle.close()
        }
        var recycled = false
        #expect(throws: (any Error).self) {
            try VMWorkspaceTransfer.trash(fixture.source.path, expectedIdentity: identity) { _ in recycled = true }
        }
        #expect(!recycled)
        try fixture.expectOriginalAndEmptyDestination()
    }

    @Test("Running VM locks and Trash failures retain the selected VM", arguments: [false, true])
    func refuseRunningOrFailedTrash(running: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let identity = try VMWorkspaceTransfer.deletionIdentity(fixture.source.path)
        let holder = Process()
        if running {
            holder.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
            holder.arguments = ["-k", "-t", "0", fixture.source.appendingPathComponent("shell/lock").path, "/bin/sh", "-c", "printf ready; exec /bin/sleep 30"]
            let ready = Pipe()
            holder.standardOutput = ready
            try holder.run()
            #expect(ready.fileHandleForReading.readData(ofLength: 5) == Data("ready".utf8))
        }
        defer { if holder.isRunning { holder.terminate(); holder.waitUntilExit() } }
        var attempted = false
        #expect(throws: (any Error).self) {
            try VMWorkspaceTransfer.trash(fixture.source.path, expectedIdentity: identity) { _ in
                attempted = true
                throw HelperError.io("Trash is unavailable")
            }
        }
        #expect(attempted == !running)
        try fixture.expectOriginalAndEmptyDestination()
    }

}
