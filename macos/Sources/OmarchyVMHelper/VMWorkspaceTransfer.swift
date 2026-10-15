import Darwin
import Foundation

/// Relocation is a verified copy followed by a preference change. The original
/// remains a recovery copy; no caller deletes it as part of this operation.
/// The VM is `shell/` (disk, UEFI variables, lock); `shell-factory/` is a
/// cache the launcher rebuilds from the app, so it is never copied.
enum VMWorkspaceTransfer {
    static let lockPath = "shell/lock"
    static let factoryCacheName = "shell-factory"

    struct Entry: Equatable {
        let relativePath: String
        let isDirectory: Bool
        let identity: String
        let signature: String
        let logicalBytes: Int64
        let allocatedBytes: Int64
    }

    static func requireExistingVM(_ path: String) throws {
        guard StorageLocationPolicy.hasValidRootMarker(in: URL(fileURLWithPath: path)),
              QEMUGPUStorageSpaceEstimate.hasRecordedPersistentDisk(stateRoot: path) else {
            throw HelperError.io("Choose the existing VM folder containing the shell folder, not the disk file or its parent folder. No saved VM was found here.")
        }
    }

    static func copy(
        from sourcePath: String,
        to destinationPath: String,
        probe: VolumeProbing = URLVolumeProbe(),
        progress: @escaping (VMTransferProgress) -> Void = { _ in },
        copyFile: (String, String) throws -> Void = { try copyRegularFile($0, $1) }
    ) throws -> String {
        progress(VMTransferProgress(phase: .checking))
        let source = try StorageLocationPolicy.validate(sourcePath, metrics: nil, probe: probe).stateRoot
        let destination = try StorageLocationPolicy.validate(destinationPath, metrics: nil, probe: probe).stateRoot
        guard source != destination,
              !destination.hasPrefix(source + "/"), !source.hasPrefix(destination + "/") else {
            throw HelperError.io("Choose a separate empty folder outside the current VM folder.")
        }
        try requireExistingVM(source)
        let manager = FileManager.default
        guard try manager.contentsOfDirectory(atPath: destination).isEmpty else {
            throw HelperError.io("The destination must be completely empty. Existing files and VMs are never replaced.")
        }
        let destinationIdentity = try entry(at: destination, relativePath: "").identity
        let lockDescriptor = try acquireWorkspaceLock(source)
        defer { close(lockDescriptor) }
        // Never open/close the locked file again in this process: POSIX record
        // locks are released by *any* close of that inode. The lock file is
        // recreated in the copy and omitted from content hashing.
        let before = try manifest(root: source)
        var totalBytes: Int64 = 0
        for item in before {
            let addition = totalBytes.addingReportingOverflow(item.logicalBytes)
            guard !addition.overflow, addition.partialValue <= Int64.max / 2 else {
                throw HelperError.io("The VM is too large to verify safely.")
            }
            totalBytes = addition.partialValue
        }
        totalBytes *= 2 // Both the source and the copied bytes are hashed.
        var verifiedBytes: Int64 = 0
        let capabilities = try probe.capabilities(at: URL(fileURLWithPath: destination))
        let needed = before.reduce(Int64(0)) { $0 + $1.allocatedBytes } + StorageSpaceRequirement.headroomBytes
        guard capabilities.availableBytes >= needed else {
            throw HelperError.io("There is not enough free space to copy this VM. At least \(StorageLocationPolicy.format(bytes: needed)) is required.")
        }
        let target = URL(fileURLWithPath: destination, isDirectory: true)
        let staging = target.deletingLastPathComponent().appendingPathComponent(".omarchy-vm-copy-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var published = false
        defer { if !published { try? manager.removeItem(at: staging) } }
        // Publish the marker only after every data file has been verified.
        let copyEntries = before.filter { $0.relativePath != StorageLocationPolicy.rootMarkerName }
            + before.filter { $0.relativePath == StorageLocationPolicy.rootMarkerName }
        for item in copyEntries {
            let output = staging.appendingPathComponent(item.relativePath).path
            if item.isDirectory {
                try manager.createDirectory(atPath: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            } else {
                progress(VMTransferProgress(phase: .copying))
                try copyFile(source + "/" + item.relativePath, output)
                let sourceDigest = try StorageIO.sha256(path: source + "/" + item.relativePath) { bytes in
                    progress(VMTransferProgress(phase: .verifying, completedBytes: verifiedBytes + bytes, totalBytes: totalBytes))
                }
                verifiedBytes += item.logicalBytes
                let copiedDigest = try StorageIO.sha256(path: output) { bytes in
                    progress(VMTransferProgress(phase: .verifying, completedBytes: verifiedBytes + bytes, totalBytes: totalBytes))
                }
                verifiedBytes += item.logicalBytes
                guard sourceDigest == copiedDigest else {
                    throw HelperError.io("The copied VM failed checksum verification. The original VM and selected location were retained.")
                }
                try StorageIO.sync(paths: [output])
            }
        }
        progress(VMTransferProgress(phase: .finishing))
        let copiedLock = staging.appendingPathComponent(lockPath).path
        let fd = open(copiedLock, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw HelperError.io("Cannot create the copied VM lock.") }
        close(fd)
        try StorageIO.sync(paths: [copiedLock])
        guard try manifest(root: source) == before else {
            throw HelperError.io("The original VM changed during copying. Relocation was cancelled; the original and selected location were retained.")
        }
        try requireExistingVM(staging.path)
        let directories = before.filter(\.isDirectory).map { staging.appendingPathComponent($0.relativePath).path }
        try StorageIO.sync(paths: directories.reversed() + [staging.path])
        // The native folder picker can add com.apple.macl after returning,
        // changing ctime without changing the folder or its contents.
        guard try entry(at: destination, relativePath: "").identity == destinationIdentity,
              try manager.contentsOfDirectory(atPath: destination).isEmpty else {
            throw HelperError.io("The destination changed while copying. Nothing was replaced.")
        }
        // rename refuses a nonempty destination. Until this atomic publication,
        // all copied files are in a private sibling, never a bootable workspace.
        guard Darwin.rename(staging.path, destination) == 0 else {
            throw HelperError.io("Could not publish the copied VM. The original and selected location were retained.")
        }
        published = true
        let parentFD = open(target.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentFD >= 0 else { throw HelperError.io("The VM copy exists, but its containing folder could not be flushed. The selected location was retained.") }
        defer { close(parentFD) }
        guard fsync(parentFD) == 0 else { throw HelperError.io("The VM copy exists, but publication could not be flushed. The selected location was retained.") }
        return destination
    }

    /// Bind confirmation to both the folder and the recorded disk. A replaced
    /// workspace or a disk changed after confirmation requires a new review.
    static func deletionIdentity(_ path: String) throws -> String {
        try requireExistingVM(path)
        guard let disk = QEMUGPUStorageSpaceEstimate.persistentDiskURL(stateRoot: path) else {
            throw HelperError.io("The selected VM disk could not be identified.")
        }
        return try entry(at: path, relativePath: "").identity + ":" + entry(at: disk.path, relativePath: "").signature
    }

    /// Run in a separate helper process, so AppKit reads cannot release POSIX
    /// locks. Trash moves the complete workspace; never erase its contents.
    static func trash(_ path: String, expectedIdentity: String,
        recycle: (URL) throws -> Void = { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }) throws {
        let source = try StorageLocationPolicy.validate(path, metrics: nil, probe: URLVolumeProbe()).stateRoot
        let lock = try acquireWorkspaceLock(source)
        defer { close(lock) }
        _ = try manifest(root: source)
        guard try deletionIdentity(source) == expectedIdentity else {
            throw HelperError.io("The selected VM changed after confirmation. Nothing was deleted. Review it and try again.")
        }
        try recycle(URL(fileURLWithPath: source, isDirectory: true))
    }

    /// Takes the launcher's lock (run-qemu-gpu.sh holds it with lockf, which
    /// conflicts with this fcntl lock), so a running VM is never copied or moved.
    private static func acquireWorkspaceLock(_ source: String) throws -> Int32 {
        let fd = open(source + "/" + lockPath, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            throw HelperError.io("Launch this VM and shut it down once before changing its files, so its lock exists.")
        }
        var info = stat()
        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o7777 == 0o600,
              fcntl(fd, F_SETLK, &lock) == 0 else {
            close(fd)
            throw HelperError.io("This VM is open or its lock is unsafe. Shut down Omarchy normally before changing its files.")
        }
        return fd
    }

    private static func entry(at path: String, relativePath: String) throws -> Entry {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR || (info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1) else {
            throw HelperError.io("The VM folder contains a symbolic link, special file, shared file, or file owned by another user. Nothing was moved: \(path)")
        }
        return Entry(relativePath: relativePath, isDirectory: info.st_mode & S_IFMT == S_IFDIR,
                     identity: "\(info.st_dev):\(info.st_ino)",
                     signature: "\(info.st_dev):\(info.st_ino):\(info.st_mode):\(info.st_nlink):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)",
                     logicalBytes: info.st_mode & S_IFMT == S_IFREG ? Int64(info.st_size) : 0,
                     allocatedBytes: info.st_mode & S_IFMT == S_IFREG ? Int64(info.st_blocks) * 512 : 0)
    }

    private static func manifest(root: String) throws -> [Entry] {
        _ = try entry(at: root, relativePath: "")
        var result: [Entry] = []
        func walk(_ relative: String) throws {
            let path = relative.isEmpty ? root : root + "/" + relative
            for name in try FileManager.default.contentsOfDirectory(atPath: path).sorted() {
                let child = relative.isEmpty ? name : relative + "/" + name
                if child == lockPath || child == factoryCacheName { continue }
                let item = try entry(at: root + "/" + child, relativePath: child)
                result.append(item)
                if item.isDirectory { try walk(child) }
            }
        }
        try walk("")
        return result
    }

    static func copyRegularFile(_ source: String, _ destination: String, forceSparseCopy: Bool = false) throws {
        let input = open(source, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw HelperError.io("Cannot read VM file: \(source)") }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1 else { throw HelperError.io("Unsafe VM source file: \(source)") }
        if forceSparseCopy || fclonefileat(input, AT_FDCWD, destination, UInt32(CLONE_NOFOLLOW)) != 0 {
            guard forceSparseCopy || errno == EXDEV || errno == ENOTSUP else { throw HelperError.io("Cannot clone VM file (errno \(errno)): \(source)") }
            let output = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw HelperError.io("Cannot create VM copy: \(destination)") }
            defer { close(output) }
            guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_DATA_SPARSE)) == 0 else {
                throw HelperError.io("Cannot finish sparse VM copy (errno \(errno)). The original VM is intact.")
            }
        }
        guard chmod(destination, 0o600) == 0 else { throw HelperError.io("Cannot protect VM copy: \(destination)") }
    }
}
