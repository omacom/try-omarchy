import Foundation

/// One disk per app session, including any settings-driven QEMU restarts.
/// The normal storage backend owns locking and disk validation inside it.
final class DisposableVMWorkspace {
    private(set) var directory: URL?

    func prepare() throws -> URL {
        if let directory { return directory }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("try-omarchy-disposable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        self.directory = directory
        return directory
    }

    /// Call only after the launcher and QEMU have exited.
    func remove() {
        guard let directory else { return }
        do {
            try FileManager.default.removeItem(at: directory)
            self.directory = nil
        } catch {
            fputs("[storage] could not remove disposable VM: \(error.localizedDescription)\n", stderr)
        }
    }
}
