import Darwin
import Foundation

/// One report from an upstream-shell guest's `try-omarchy-guest-status`
/// service on the `dev.tryomarchy.guest` port. Protocol 1. The report is
/// advisory: it only decides what the launcher shows and offers.
struct ShellGuestReport: Codable, Equatable {
    struct Kernel: Codable, Equatable {
        let running: String
        let installed: String?
    }

    struct Install: Codable, Equatable {
        let requested: String
        let result: String
        let message: String
    }

    let `protocol`: Int
    let package: String?
    let omarchy: String?
    let channel: String?
    let kernel: Kernel?
    let install: Install?

    /// The newest guest protocol this app understands. A guest that reports a
    /// newer one still works; the app only reads the fields it knows.
    static let supportedProtocol = 1
    static let maximumLineBytes = 4096

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumLineBytes else { throw HelperError.io("guest status exceeds limit") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        let texts = [value.package, value.omarchy, value.channel, value.kernel?.running, value.kernel?.installed,
                     value.install?.requested, value.install?.result, value.install?.message].compactMap { $0 }
        guard value.protocol >= 1, value.protocol <= 1000,
              texts.allSatisfy({ $0.count <= 512 && !$0.contains(where: { $0.isNewline }) }) else {
            throw HelperError.io("invalid guest status")
        }
        return value
    }
}

/// The last report, kept beside the VM's disk so the launcher can show it
/// before the next boot.
struct ShellGuestStatusRecord: Codable {
    let receivedAt: Date
    let report: ShellGuestReport

    static func read(_ url: URL) -> Self? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 8192,
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Self.self, from: data)
    }
}

/// Compares pacman versions (`[epoch:]pkgver-pkgrel`) closely enough for the
/// try-omarchy package's own numbering: numeric dot-separated parts, then pkgrel.
enum PacmanVersion {
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        func parts(_ value: String) -> [Int] {
            value.split(whereSeparator: { $0 == "." || $0 == "-" || $0 == ":" || $0 == "+" })
                .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let left = parts(lhs), right = parts(rhs)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

/// `--bridge-guest-status PID SOCKET STATUS_FILE`: reads the guest's reports
/// for as long as QEMU runs and keeps the latest in STATUS_FILE.
enum ShellGuestStatusBridge {
    static func run(targetPID: pid_t, socketPath: String, statusPath: String) throws {
        guard let identity = KernelProcessIdentity.capture(processIdentifier: targetPID),
              identity.isQEMUSystemProcess else {
            throw HelperError.io("guest status target is not QEMU")
        }
        let statusURL = URL(fileURLWithPath: statusPath)
        var info = stat()
        let parent = statusURL.deletingLastPathComponent().path
        guard lstat(parent, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            throw HelperError.io("guest status directory is not private to this user")
        }
        let descriptor = try NativeBridgeSocket.connectSecure(path: socketPath, label: "guest status")
        defer { Darwin.close(descriptor) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var buffer = Data()
        var discarding = false
        var bytes = [UInt8](repeating: 0, count: 4096)
        while identity.isStillRunning {
            var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, 1000)
            if ready < 0 && errno != EINTR { throw HelperError.io("guest status poll failed") }
            guard ready > 0 else { continue }
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return
            }
            for byte in bytes.prefix(count) {
                if byte == 10 {
                    if !discarding, let report = try? ShellGuestReport.decode(buffer),
                       let data = try? encoder.encode(ShellGuestStatusRecord(receivedAt: Date(), report: report)) {
                        try? data.write(to: statusURL, options: .atomic)
                    }
                    buffer.removeAll(keepingCapacity: true)
                    discarding = false
                } else if !discarding {
                    buffer.append(byte)
                    if buffer.count > ShellGuestReport.maximumLineBytes {
                        discarding = true
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
            }
        }
    }
}

/// What the start menu says about an upstream-shell VM's guest.
struct ShellGuestPresentation: Equatable {
    let lines: [String]
    let isCurrent: Bool

    var detail: String { lines.joined(separator: " · ") }

    /// The version of the try-omarchy package bundled in this app, from its file name.
    static func bundledPackageVersion(bundle: Bundle = .main) -> String? {
        guard let directory = bundle.resourceURL?.appendingPathComponent("guest-packages"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        return names.compactMap(packageVersion(fileName:)).first
    }

    static func packageVersion(fileName: String) -> String? {
        let prefix = "try-omarchy-"
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(".pkg.tar.zst") else { return nil }
        // try-omarchy-<pkgver>-<pkgrel>-<arch>.pkg.tar.zst
        let parts = fileName.dropFirst(prefix.count).dropLast(".pkg.tar.zst".count).split(separator: "-")
        guard parts.count == 3 else { return nil }
        return "\(parts[0])-\(parts[1])"
    }

    static func make(record: ShellGuestStatusRecord?, bundledPackage: String?) -> Self {
        guard let report = record?.report else {
            return Self(lines: ["Versions appear after Omarchy starts"], isCurrent: true)
        }
        let system = [report.omarchy.map { "Omarchy \($0)" }, report.channel].compactMap { $0 }
        var integrations = report.package.map { "Integrations \($0)" }
        var current = true
        if let bundledPackage, let package = report.package,
           PacmanVersion.compare(package, bundledPackage) == .orderedAscending {
            current = false
            integrations = "Integrations \(package) → \(bundledPackage) next launch"
        }
        if let install = report.install, install.result == "failed" {
            current = false
            integrations = "Integration update failed: \(install.message)"
        }
        let lines = [system.isEmpty ? nil : system.joined(separator: " · "), integrations].compactMap { $0 }
        return Self(lines: lines.isEmpty ? ["No version reported"] : lines, isCurrent: current)
    }
}
