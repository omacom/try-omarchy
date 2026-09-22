import Darwin
import Foundation

/// One deliberately narrow guest request on dev.tryomarchy.settings.
/// Oversized/unknown lines are discarded without interpreting any payload.
struct SettingsRequestBuffer {
    private var line = Data()
    private var discarding = false

    mutating func consume(_ data: Data) -> Bool {
        var requested = false
        for byte in data {
            if byte == 10 {
                requested = requested || (!discarding && line == Data("open-settings".utf8))
                line.removeAll(keepingCapacity: true)
                discarding = false
            } else if !discarding {
                if line.count < 64 {
                    line.append(byte)
                } else {
                    line.removeAll(keepingCapacity: true)
                    discarding = true
                }
            }
        }
        return requested
    }
}

/// Lives in the AppKit process so requests can present the existing window.
@MainActor
final class NativeSettingsBridge {
    private var source: DispatchSourceRead?
    private var requests = SettingsRequestBuffer()
    private let descriptor: Int32
    private let openSettings: () -> Bool

    convenience init(socketPath: String, openSettings: @escaping () -> Bool) throws {
        let descriptor = try NativeBridgeSocket.connectSecure(path: socketPath, label: "settings")
        try self.init(descriptor: descriptor, openSettings: openSettings)
    }

    /// Takes ownership of a connected descriptor; also used with socketpair in tests.
    init(descriptor: Int32, openSettings: @escaping () -> Bool) throws {
        self.descriptor = descriptor
        self.openSettings = openSettings
        var noSignal: Int32 = 1
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            Darwin.close(descriptor)
            throw HelperError.io("cannot configure settings channel")
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.readRequests() }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        self.source = source
        source.resume()
    }

    deinit { source?.cancel() }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func readRequests() {
        guard source != nil else { return }
        var buffer = [UInt8](repeating: 0, count: 512)
        // Bound work on the UI thread even if the guest floods the channel.
        var requested = false
        for _ in 0..<16 {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                let nextRequest = requests.consume(Data(buffer.prefix(count)))
                requested = requested || nextRequest
            } else if count < 0 && errno == EINTR {
                continue
            } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                break
            } else {
                stop()
                return
            }
        }
        guard requested else { return }
        let reply = Data((openSettings() ? "opened\n" : "unavailable\n").utf8)
        let written = reply.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        if written != reply.count { stop() }
    }
}
