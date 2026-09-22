import CryptoKit
import Darwin
import Foundation

/// Small storage primitives shared by the launcher. Transaction ordering and
/// workspace locking stay in qemu-persistent-storage.sh.
enum StorageIO {
    static func sha256(path: String) throws -> String {
        let handle: FileHandle
        if path == "-" {
            handle = .standardInput
        } else {
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw HelperError.io("Cannot open file for SHA-256: \(path)") }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                close(fd)
                throw HelperError.io("SHA-256 requires a regular file: \(path)")
            }
            handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        defer { if path != "-" { try? handle.close() } }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 8 * 1024 * 1024), !data.isEmpty {
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Callers list newly written files before their containing directory,
    /// then sync the parent again after publishing with rename. Syncing only
    /// a directory would not flush the contents of the files inside it.
    static func sync(paths: [String]) throws {
        for path in paths {
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw HelperError.io("Cannot open storage checkpoint: \(path)") }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(),
                  (info.st_mode & S_IFMT == S_IFDIR && info.st_mode & 0o7777 == 0o700)
                    || (info.st_mode & S_IFMT == S_IFREG && info.st_mode & 0o7777 == 0o600
                        && info.st_nlink == 1) else {
                throw HelperError.io("Unsafe storage checkpoint: \(path)")
            }
            while fsync(fd) != 0 {
                guard errno == EINTR else {
                    throw HelperError.io("Cannot flush storage checkpoint: \(path) (errno \(errno))")
                }
            }
        }
    }
}
