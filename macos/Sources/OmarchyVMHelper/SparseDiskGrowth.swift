import Darwin
import Foundation

/// Called only after the launcher selects and locks a validated workspace.
/// Bind growth to the inspected inode and never truncate a newer, larger disk.
enum SparseDiskGrowth {
    static func grow(path: String, expectedBytes: Int64, targetBytes: Int64, identity: String) throws {
        guard expectedBytes > 0, targetBytes > expectedBytes, targetBytes <= 8192 << 30 else {
            throw HelperError.io("Invalid disk growth capacity; shrinking is not supported.")
        }
        let fd = open(path, O_RDWR | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw HelperError.io("Cannot open the VM disk for growth.") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o7777 == 0o600,
              info.st_uid == getuid(), info.st_nlink == 1,
              info.st_size == expectedBytes,
              "\(info.st_dev):\(info.st_ino)" == identity else {
            throw HelperError.io("The VM disk changed before growth; refusing to resize it.")
        }
        guard ftruncate(fd, targetBytes) == 0, fsync(fd) == 0,
              fstat(fd, &info) == 0, info.st_size == targetBytes else {
            throw HelperError.io("Could not finish expanding the VM disk. Its contents were retained; retry the launch.")
        }
    }
}
