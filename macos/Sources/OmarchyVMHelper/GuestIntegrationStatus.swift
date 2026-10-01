import AppKit
import Darwin
import Foundation

struct GuestIntegrationReport: Codable, Equatable {
    let schema: Int
    let version: Int
    let identity: String
    let components: [String: String]
    let paired: Bool

    /// Components this app's bundle installs. Additional components indicate
    /// that the guest needs a matching or newer app.
    static let supportedComponents: Set<String> = ["bootstrap", "sudo", "battery"]

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4096 else { throw HelperError.io("integration status exceeds limit") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        let allowed = supportedComponents.union(["clock", "holds", "onepassword"])
        guard value.schema == 1, value.version > 0, value.version <= 100000,
              value.identity.count == 64,
              value.identity.allSatisfy({ "0123456789abcdef".contains($0) }),
              Set(value.components.keys).isSubset(of: allowed),
              Set(["bootstrap", "sudo"]).isSubset(of: Set(value.components.keys)),
              value.components.values.allSatisfy({ ["current", "repair", "disabled"].contains($0) }) else {
            throw HelperError.io("invalid integration status")
        }
        return value
    }

    func summary(expectedIdentity: String?) -> String {
        if version > 1 { return "Newer guest integration version" }
        guard let expectedIdentity else { return "Bundle status unavailable" }
        if !Set(components.keys).isSubset(of: Self.supportedComponents) {
            return "Additional guest integrations · use matching app"
        }
        if identity != expectedIdentity { return "Updates available" }
        if components.values.contains("repair") { return "Repair available" }
        if !paired { return "Current · Touch ID setup available" }
        return "Up to date"
    }
}

struct GuestIntegrationCache: Codable {
    let checkedAt: Date
    let state: String
    let report: GuestIntegrationReport?

    static func url(storageRoot: URL?) -> URL? {
        guard let storageRoot,
              let attributes = try? FileManager.default.attributesOfItem(
                atPath: storageRoot.appendingPathComponent("disks/current/rootfs.ext4").path),
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return storageRoot.appendingPathComponent("integration-status-\(inode.uint64Value).json")
    }

    static func read(_ url: URL?) -> Self? {
        guard let url, let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? 100000 > 0,
              (attributes[.size] as? NSNumber)?.intValue ?? 100000 <= 8192,
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        if let report = value.report,
           (try? GuestIntegrationReport.decode(JSONEncoder().encode(report))) == nil { return nil }
        return value
    }

    static var bundledIdentity: String? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("integrations/manifest.json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["identity"] as? String
    }

    var summary: String {
        if state == "no-response" { return "Setup or repair may be needed" }
        if state == "checking" { return "Check incomplete · retry on launch" }
        return report?.summary(expectedIdentity: Self.bundledIdentity) ?? "Not checked yet"
    }
}

@MainActor
final class GuestIntegrationBridge: NSObject {
    private let descriptor: Int32
    private let cacheURL: URL
    private var timer: Timer?
    private var buffer = Data()
    private var discardingLine = false
    private let started = ProcessInfo.processInfo.systemUptime
    private var lastResponse: TimeInterval?
    private var lastState = ""
    private let targetIdentity: KernelProcessIdentity

    init(targetPID: pid_t, socketPath: String, cachePath: String) throws {
        guard let identity = KernelProcessIdentity.capture(processIdentifier: targetPID), identity.isQEMUSystemProcess else {
            throw HelperError.io("integration target is not QEMU")
        }
        self.targetIdentity = identity
        cacheURL = URL(fileURLWithPath: cachePath)
        var info = stat()
        let parent = cacheURL.deletingLastPathComponent().path
        guard lstat(parent, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            throw HelperError.io("integration cache directory is not private to this user")
        }
        descriptor = try NativeBridgeSocket.connectSecure(path: socketPath, label: "integration status")
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        super.init()
    }

    func run() {
        NSApp.setActivationPolicy(.accessory)
        save(state: "checking", report: nil)
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .modalPanel)
        }
        NSApp.run()
        Darwin.close(descriptor)
    }

    private func save(state: String, report: GuestIntegrationReport?) {
        let value = GuestIntegrationCache(checkedAt: Date(), state: state, report: report)
        if let data = try? JSONEncoder().encode(value) {
            do { try data.write(to: cacheURL, options: .atomic) }
            catch { fputs("[integrations] Could not retain status: \(error.localizedDescription)\n", stderr) }
        }
        lastState = state
    }

    private func tick() {
        if !targetIdentity.isStillRunning { NSApp.terminate(nil); return }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        if count > 0 {
            for byte in bytes.prefix(count) {
                if byte == 10 {
                    if !discardingLine, let report = try? GuestIntegrationReport.decode(buffer) {
                        lastResponse = ProcessInfo.processInfo.systemUptime
                        save(state: "reported", report: report)
                    }
                    buffer.removeAll(keepingCapacity: true)
                    discardingLine = false
                } else if !discardingLine {
                    buffer.append(byte)
                    if buffer.count > 4096 {
                        discardingLine = true
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
            }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - (lastResponse ?? started)
        if elapsed > 120 && lastState != "no-response" { save(state: "no-response", report: nil) }
    }
}
