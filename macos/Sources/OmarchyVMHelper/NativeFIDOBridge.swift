import AppKit
import Darwin
import Foundation

final class NativeFIDOBridge: @unchecked Sendable {
    typealias DeviceOpener = (@escaping ([UInt8]) -> Void, @escaping () -> Void) throws -> FIDOReportDevice

    private var descriptor: Int32
    private let processAlive: () -> Bool
    private let openDevice: DeviceOpener
    private let now: () -> ContinuousClock.Instant
    private let stopLock = NSLock()
    private var stopped = false
    private var output = FIDOOutputBuffer()
    private var failure: Error?
    private var session: FIDOForwardingSession?

    convenience init(targetPID: pid_t, socketPath: String, registryID: UInt64) throws {
        guard getuid() != 0,
              let identity = KernelProcessIdentity.capture(processIdentifier: targetPID),
              identity.isQEMUSystemProcess else {
            throw HelperError.io("FIDO forwarding needs a normal Mac user and a QEMU system process")
        }
        let descriptor = try NativeBridgeSocket.connectSecure(path: socketPath, label: "FIDO bridge")
        try self.init(descriptor: descriptor, processAlive: { identity.isStillRunning }, openDevice: { received, failed in
            try HostFIDODevices.open(registryID: registryID, received: received, failed: failed)
        })
    }

    init(descriptor: Int32, processAlive: @escaping () -> Bool,
         now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
         openDevice: @escaping DeviceOpener) throws {
        self.descriptor = descriptor
        self.processAlive = processAlive
        self.now = now
        self.openDevice = openDevice
        var noSignal: Int32 = 1
        guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            Darwin.close(descriptor)
            self.descriptor = -1
            throw HelperError.io("cannot configure the FIDO channel")
        }
    }

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    func stop() {
        stopLock.lock()
        stopped = true
        stopLock.unlock()
    }

    private var hasStopped: Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopped
    }

    func run() throws {
        let workspace = NSWorkspace.shared.notificationCenter
        let sleepObserver = workspace.addObserver(forName: NSWorkspace.willSleepNotification,
                                                   object: nil, queue: nil) { [weak self] _ in self?.stop() }
        defer {
            workspace.removeObserver(sleepObserver)
            session?.close()
            if output.bytes.isEmpty {
                let goodbye = FIDOFrame.bye.bytes
                _ = goodbye.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
            }
            Darwin.close(descriptor)
            descriptor = -1
        }
        session = FIDOForwardingSession { [weak self] in
            guard let self else { throw HelperError.io("FIDO bridge stopped") }
            return try self.openDevice({ [weak self] report in
                guard let self else { return }
                do {
                    if let frame = try self.session?.receivedReport(report) { try self.output.append(frame) }
                } catch { self.failure = error }
            }, { [weak self] in self?.failure = HelperError.io("selected FIDO key was disconnected") })
        }
        var reader = FIDOFrameReader()
        var chunk = [UInt8](repeating: 0, count: 4096)
        var deadline = now().advanced(by: .seconds(30))
        while !hasStopped, processAlive(), session?.isClosed == false {
            if let failure { throw failure }
            guard now() < deadline else { throw HelperError.io("FIDO guest lease expired; the key was released") }
            var event = pollfd(fd: descriptor, events: Int16(POLLIN | (output.bytes.isEmpty ? 0 : POLLOUT)), revents: 0)
            let result = Darwin.poll(&event, 1, 20)
            if result < 0 {
                if errno == EINTR { continue }
                throw HelperError.io("cannot poll the FIDO channel")
            }
            if event.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { return }
            if event.revents & Int16(POLLIN) != 0 {
                let count = Darwin.read(descriptor, &chunk, chunk.count)
                if count == 0 { try reader.finish(); return }
                if count > 0 {
                    for frame in try reader.feed(Array(chunk[0..<count])) {
                        let wasReady = session?.isReady == true
                        if let response = try session?.receive(frame) { try output.append(response) }
                        if !wasReady, session?.isReady == true {
                            fputs("[fido-bridge] The selected FIDO interface belongs to this VM until forwarding stops.\n", stderr)
                        }
                        deadline = now().advanced(by: .seconds(10))
                    }
                } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                    throw HelperError.io("cannot read the FIDO channel")
                }
            }
            if event.revents & Int16(POLLOUT) != 0, !output.bytes.isEmpty {
                let count = output.bytes.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
                if count > 0 { output.consume(count) }
                else if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                    throw HelperError.io("cannot write the FIDO channel")
                }
            }
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.001, false)
        }
    }
}
