import AppKit
import Darwin
import Foundation

struct GuestIntegrationReport: Codable, Equatable {
    let schema: Int
    let version: Int
    let identity: String
    let components: [String: String]
    let paired: Bool

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4096 else { throw HelperError.io("integration status exceeds limit") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        let allowed = Set(["bootstrap", "sudo", "clock", "holds", "onepassword"])
        guard value.schema == 1, value.version > 0, value.version <= 100000,
              value.identity.count == 64,
              value.identity.allSatisfy({ "0123456789abcdef".contains($0) }),
              Set(value.components.keys).isSubset(of: allowed),
              Set(["sudo", "clock", "holds"]).isSubset(of: Set(value.components.keys)),
              value.components.values.allSatisfy({ ["current", "repair", "disabled"].contains($0) }) else {
            throw HelperError.io("invalid integration status")
        }
        return value
    }

    func summary(expectedIdentity: String?) -> String {
        if version > 1 { return "Newer guest integration version" }
        guard let expectedIdentity else { return "Bundle status unavailable" }
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
enum GuestIntegrationSetup {
    static let command = "sudo mkdir -p /mnt/try-omarchy-updates && (mountpoint -q /mnt/try-omarchy-updates || sudo mount -t 9p -o trans=virtio,version=9p2000.L,ro tryomarchy-updates /mnt/try-omarchy-updates) && bash /mnt/try-omarchy-updates/setup"

    static func show(window: NSWindow? = nil) {
        let alert = NSAlert()
        alert.messageText = "Review VM integrations"
        alert.informativeText = "Inside Omarchy, open Setup > Try Omarchy Integrations. If that entry is missing, copy the command below and paste it into an Omarchy terminal.\n\nReview Touch ID, clock recovery, and compatibility updates before installing. Have your Linux password ready. Your existing VM is preserved."
        alert.addButton(withTitle: "Copy setup command")
        alert.addButton(withTitle: "Close")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 64))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let field = NSTextView(frame: scroll.contentView.bounds)
        field.string = command
        field.isEditable = false
        field.isSelectable = true
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.textContainerInset = NSSize(width: 6, height: 6)
        field.autoresizingMask = [.width]
        field.textContainer?.widthTracksTextView = true
        scroll.documentView = field
        alert.accessoryView = scroll
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: completion) }
        else { completion(alert.runModal()) }
    }
}

@MainActor
final class GuestIntegrationBridge: NSObject {
    private let descriptor: Int32
    private let cacheURL: URL
    private var item: NSStatusItem?
    private var timer: Timer?
    private var buffer = Data()
    private var discardingLine = false
    private let started = ProcessInfo.processInfo.systemUptime
    private var lastResponse: TimeInterval?
    private var lastState = ""
    private var latestReport: GuestIntegrationReport?
    private var offeredReview = false
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
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item?.button?.image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: "VM integrations")
        item?.button?.image?.isTemplate = true
        let menu = NSMenu()
        let status = NSMenuItem(title: "Checking…", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        let review = NSMenuItem(title: "Review VM integrations…", action: #selector(review), keyEquivalent: "")
        review.target = self
        menu.addItem(review)
        item?.menu = menu
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

    @objc private func review() { GuestIntegrationSetup.show() }

    private func save(state: String, report: GuestIntegrationReport?) {
        let summary = report?.summary(expectedIdentity: GuestIntegrationCache.bundledIdentity)
            ?? (state == "checking" ? "Checking…" : "Setup or repair needed")
        item?.menu?.items.first?.title = summary
        item?.button?.toolTip = "VM integrations: \(summary)"
        item?.button?.setAccessibilityLabel("VM integrations: \(summary)")
        let value = GuestIntegrationCache(checkedAt: Date(), state: state, report: report)
        if let data = try? JSONEncoder().encode(value) {
            do { try data.write(to: cacheURL, options: .atomic) }
            catch { fputs("[integrations] Could not retain status: \(error.localizedDescription)\n", stderr) }
        }
        lastState = state
        latestReport = report
    }

    private func offerReviewIfNeeded() {
        guard !offeredReview, let expected = GuestIntegrationCache.bundledIdentity else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let needsReview = lastState == "no-response"
            || (latestReport.map { $0.version <= 1 && ($0.identity != expected || $0.components.values.contains("repair")) } ?? false)
        guard needsReview, elapsed >= 30 else { return }
        let noticeURL = cacheURL.deletingPathExtension().appendingPathExtension("notice")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: noticeURL.path),
           (attributes[.size] as? NSNumber)?.intValue == 64,
           let data = try? Data(contentsOf: noticeURL), data == Data(expected.utf8) {
            offeredReview = true
            return
        }
        offeredReview = true
        // A repeating timer cannot fire again while its own callback presents a modal.
        DispatchQueue.main.async { [weak self] in
            self?.presentReview(expected: expected, noticeURL: noticeURL)
        }
    }

    private func presentReview(expected: String, noticeURL: URL) {
        guard targetIdentity.isStillRunning else { return }
        let alert = NSAlert()
        alert.messageText = "Review your VM integrations"
        alert.informativeText = lastState == "no-response"
            ? "This VM has not answered its integration check. It may still be starting, or may need the setup included with this app. You can add new features without resetting your VM."
            : "This app includes integration updates or repairs for your existing VM. Review them inside Omarchy when you are ready. Installation needs your Linux password."
        alert.addButton(withTitle: "Review setup")
        alert.addButton(withTitle: "Later")
        NSApp.activate()
        let response = alert.runModal()
        do { try Data(expected.utf8).write(to: noticeURL, options: .atomic) }
        catch { fputs("[integrations] Could not retain review preference.\n", stderr) }
        if response == .alertFirstButtonReturn { GuestIntegrationSetup.show() }
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
        offerReviewIfNeeded()
    }
}
