import Darwin
import Foundation

struct NetworkLinkSnapshot: Equatable {
    let generation: UInt64
    let isUp: Bool

    static func parse(_ data: Data) throws -> Self {
        guard data.count <= 64, let text = String(data: data, encoding: .utf8),
              text.hasSuffix("\n") else {
            throw HelperError.io("Invalid network link state")
        }
        let fields = text.dropLast().split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 2, !fields[0].isEmpty,
              fields[0].allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let generation = UInt64(fields[0]), generation > 0,
              fields[1] == "up" || fields[1] == "down" else {
            throw HelperError.io("Invalid network link state")
        }
        return Self(generation: generation, isUp: fields[1] == "up")
    }
}

enum NetworkLinkStateReader {
    static func read(path: String, expectedOwner: uid_t = 0) throws -> NetworkLinkSnapshot {
        let url = URL(fileURLWithPath: path)
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw HelperError.io("Invalid network link state path")
        }
        // Session directories grant traversal, but not listing or a read fd.
        let directoryPath = url.deletingLastPathComponent().path
        var directoryInformation = stat()
        guard lstat(directoryPath, &directoryInformation) == 0,
              directoryInformation.st_mode & S_IFMT == S_IFDIR,
              directoryInformation.st_uid == expectedOwner,
              directoryInformation.st_mode & 0o022 == 0 else {
            throw HelperError.io("Network session directory has unsafe ownership or permissions")
        }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw HelperError.io("Network link state is unavailable") }
        defer { close(descriptor) }
        var currentDirectory = stat()
        guard lstat(directoryPath, &currentDirectory) == 0,
              currentDirectory.st_mode & S_IFMT == S_IFDIR,
              currentDirectory.st_uid == expectedOwner,
              currentDirectory.st_mode & 0o022 == 0,
              currentDirectory.st_dev == directoryInformation.st_dev,
              currentDirectory.st_ino == directoryInformation.st_ino else {
            throw HelperError.io("Network session directory changed while reading link state")
        }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == expectedOwner, information.st_mode & 0o022 == 0,
              information.st_nlink == 1, information.st_size > 0, information.st_size <= 64 else {
            throw HelperError.io("Network link state has unsafe metadata")
        }
        var bytes = [UInt8](repeating: 0, count: 65)
        var count: Int
        repeat { count = Darwin.read(descriptor, &bytes, bytes.count) } while count < 0 && errno == EINTR
        guard count > 0, count <= 64 else { throw HelperError.io("Cannot read network link state") }
        return try NetworkLinkSnapshot.parse(Data(bytes.prefix(count)))
    }
}

struct NetworkLinkReducer {
    private(set) var applied: NetworkLinkSnapshot?

    mutating func apply(
        _ snapshot: NetworkLinkSnapshot,
        connectionFactory: () throws -> QMPConnection,
        isTargetAlive: () -> Bool,
        carrierDelay: () -> Void = { Thread.sleep(forTimeInterval: 0.25) }
    ) throws {
        if let applied, snapshot.generation <= applied.generation { return }
        let connection = try connectionFactory()
        defer { connection.close() }
        try apply(snapshot, setLink: { isUp in
            guard isTargetAlive() else { throw HelperError.io("Network link target exited") }
            _ = try connection.execute("set_link", arguments: ["name": "omarchy-nic", "up": isUp])
        }, carrierDelay: carrierDelay)
    }

    mutating func apply(
        _ snapshot: NetworkLinkSnapshot,
        setLink: (Bool) throws -> Void,
        carrierDelay: () -> Void = { Thread.sleep(forTimeInterval: 0.25) }
    ) throws {
        if let applied, snapshot.generation <= applied.generation { return }
        if snapshot.isUp {
            // An atomic status update can replace down before the watcher reads it.
            // Pulse carrier for every new up generation, including late attachment.
            try setLink(false)
            carrierDelay()
            try setLink(true)
        } else {
            try setLink(false)
        }
        applied = snapshot
    }
}

enum NetworkLinkBridge {
    static func run(targetPID: pid_t, qmpSocketPath: String, statusPath: String) throws {
        guard let identity = KernelProcessIdentity.capture(processIdentifier: targetPID),
              identity.isQEMUSystemProcess else {
            throw HelperError.io("Network link target is not a running QEMU process")
        }
        var reducer = NetworkLinkReducer()
        var lastError: String?
        while identity.isStillRunning {
            do {
                let snapshot = try NetworkLinkStateReader.read(path: statusPath)
                try reducer.apply(snapshot, connectionFactory: {
                    try QMPConnection(socketPath: qmpSocketPath, identifierPrefix: "omarchy-network-link", expectedPeerPID: targetPID)
                }, isTargetAlive: { identity.isStillRunning })
                lastError = nil
            } catch {
                let message = String(describing: error)
                if message != lastError {
                    fputs("Network link recovery will retry: \(message)\n", stderr)
                    lastError = message
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
}
