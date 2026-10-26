import Darwin
import Foundation

/// Starts the kit's helper in run mode, follows its events and shuts it down.
/// Events arrive on a private serial queue, in order, and end with `exited`,
/// which comes once the helper has ended, so the caller may start again from it.
public final class VMRunClient: @unchecked Sendable {
    public typealias EventHandler = @Sendable (VMRunEvent) -> Void

    public let kit: TryOmarchyKit
    private let queue = DispatchQueue(label: "dev.tryomarchy.kit.client")
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var onEvent: EventHandler = { _ in }
    private var outputBuffer = Data()
    private var errorTail = Data()
    private var outputClosed = false
    private var terminationStatus: Int32?
    private var finished = true
    private var exitEvent: VMRunEvent?
    private var protocolFailed = false
    /// Each run's callbacks carry its number, so a late callback from an
    /// earlier run never touches the next one.
    private var run = 0

    public static let errorTailBytes = 16_384
    /// How long `terminate()` waits for the helper before it kills it.
    public static let terminationGrace: TimeInterval = 5
    static let secondSignalDelay: TimeInterval = 0.2

    public init(kit: TryOmarchyKit) {
        self.kit = kit
    }

    public var isRunning: Bool { lock.withLock { !finished } }

    /// The end of the helper's diagnostic output, for error reports.
    public var recentStandardError: String {
        lock.withLock { String(decoding: errorTail, as: UTF8.self) }
    }

    /// Fails before anything starts on a Mac that cannot run the VM.
    public static func preflight(
        operatingSystem: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> VMRunError? {
        guard operatingSystem.majorVersion >= 15 else {
            return VMRunError(code: .macOSTooOld, message: "Omarchy in a window needs macOS 15 or newer.")
        }
        #if arch(arm64)
        var supported: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.hv_support", &supported, &size, nil, 0) == 0, supported == 1 else {
            return VMRunError(code: .hypervisorUnavailable,
                              message: "This Mac does not offer the virtualization Omarchy needs.")
        }
        return nil
        #else
        return VMRunError(code: .hypervisorUnavailable, message: "Omarchy in a window needs an Apple Silicon Mac.")
        #endif
    }

    /// The caller's environment without the launcher's development and test
    /// settings, which would otherwise change the VM the run mode starts.
    public static func cleanEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in
            !key.hasPrefix("OMARCHY_") && !key.hasPrefix("TRYOMARCHY_") && !key.hasPrefix("SDL_")
        }
    }

    /// The configuration without what the kit's manifest does not list, which
    /// an older kit would refuse.
    public static func offered(_ configuration: VMRunConfiguration,
                               by manifest: TryOmarchyKitManifest?) -> VMRunConfiguration {
        var configuration = configuration
        if manifest?.supports(.nativeExports) != true { configuration.nativeExports = false }
        return configuration
    }

    public func start(
        _ configuration: VMRunConfiguration,
        environment: [String: String] = VMRunClient.cleanEnvironment(ProcessInfo.processInfo.environment),
        onEvent: @escaping EventHandler
    ) throws {
        let configurationLine = try Self.offered(configuration, by: try? kit.manifest()).encodedLine()
        let helper = try kit.helperURL()
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = helper
        process.arguments = ["--run-vm"]
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        // A helper that already exited must not take this process with it.
        _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let run = try lock.withLock { () -> Int in
            guard finished else { throw VMRunError(code: .launchFailed, message: "Omarchy is already running.") }
            self.run += 1
            self.process = process
            self.input = inputPipe.fileHandleForWriting
            self.onEvent = onEvent
            outputBuffer = Data()
            errorTail = Data()
            outputClosed = false
            terminationStatus = nil
            finished = false
            exitEvent = nil
            protocolFailed = false
            return self.run
        }

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            guard let self else { return }
            self.queue.async { self.receiveOutput(data, run: run) }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let self else { return }
            self.lock.withLock {
                guard self.run == run else { return }
                self.errorTail.append(data)
                if self.errorTail.count > Self.errorTailBytes {
                    self.errorTail = self.errorTail.suffix(Self.errorTailBytes)
                }
            }
        }
        process.terminationHandler = { [weak self] process in
            let status = Self.status(of: process)
            guard let self else { return }
            self.queue.async { self.receiveTermination(status, run: run) }
            // The output closes when the helper exits; wait briefly for it.
            self.queue.asyncAfter(deadline: .now() + 2) { self.finishIfNeeded(force: true, run: run) }
        }

        do {
            try process.run()
        } catch {
            lock.withLock {
                finished = true
                self.process = nil
                self.input = nil
            }
            throw VMRunError(code: .launchFailed, message: "Could not start Omarchy: \(error.localizedDescription)")
        }
        try? inputPipe.fileHandleForWriting.write(contentsOf: configurationLine)
    }

    /// Asks Omarchy to shut down, as its own Shut Down does. The helper stops
    /// the VM if Omarchy has not shut down within a minute; `exited` follows
    /// either way.
    public func shutDown() {
        let input = lock.withLock { finished ? nil : self.input }
        guard let input, let line = try? VMRunCommand.shutdown.encodedLine() else { return }
        try? input.write(contentsOf: line)
    }

    /// Stops the VM at once, as pulling the power would, without waiting for
    /// Omarchy to shut down: unsaved work in Omarchy is lost. The helper reads
    /// a first signal as `shutDown()` and a second as stop now, so this sends
    /// two. A helper still running after `killAfter` seconds is killed, and
    /// its launcher, which stops QEMU, is asked to stop. `exited` follows.
    public func terminate(killAfter: TimeInterval = VMRunClient.terminationGrace) {
        guard let (process, run) = runningProcess() else { return }
        let helper = process.processIdentifier
        kill(helper, SIGTERM)
        queue.asyncAfter(deadline: .now() + Self.secondSignalDelay) { [weak self] in
            guard self?.runningProcess()?.1 == run else { return }
            kill(helper, SIGTERM)
        }
        queue.asyncAfter(deadline: .now() + max(killAfter, Self.secondSignalDelay)) { [weak self] in
            guard self?.runningProcess()?.1 == run else { return }
            for child in Self.children(of: helper) { kill(child, SIGTERM) }
            kill(helper, SIGKILL)
        }
    }

    private func runningProcess() -> (Process, Int)? {
        lock.withLock {
            guard !finished, let process, process.isRunning else { return nil }
            return (process, run)
        }
    }

    private static func children(of parent: pid_t) -> [pid_t] {
        var children = [pid_t](repeating: 0, count: 256)
        let count = proc_listchildpids(parent, &children, Int32(children.count * MemoryLayout<pid_t>.stride))
        return children.prefix(max(0, Int(count))).filter { $0 > 0 }
    }

    private func receiveOutput(_ data: Data, run: Int) {
        guard lock.withLock({ self.run == run && !finished }) else { return }
        guard !data.isEmpty else {
            lock.withLock { outputClosed = true }
            finishIfNeeded(force: false, run: run)
            return
        }
        lock.withLock { outputBuffer.append(data) }
        while let line = nextLine() {
            switch Result(catching: { try VMRunEvent.decode(line: line) }) {
            case .success(let event):
                deliver(event)
            case .failure(VMRunProtocolError.unknownEvent):
                continue
            case .failure:
                failProtocol()
            }
        }
        let overflow = lock.withLock { outputBuffer.count >= VMRunProtocol.maximumLineBytes }
        if overflow {
            lock.withLock { outputBuffer.removeAll() }
            failProtocol()
        }
    }

    private func nextLine() -> Data? {
        lock.withLock {
            guard let newline = outputBuffer.firstIndex(of: 0x0A) else { return nil }
            let line = outputBuffer[outputBuffer.startIndex...newline]
            outputBuffer.removeSubrange(outputBuffer.startIndex...newline)
            return Data(line)
        }
    }

    /// A helper that does not speak the protocol is not trusted to keep
    /// running the VM: the client reports it once and stops the helper.
    private func failProtocol() {
        let first = lock.withLock { () -> Bool in
            defer { protocolFailed = true }
            return !protocolFailed
        }
        guard first else { return }
        deliver(.error(VMRunError(code: .launchFailed, message: "Omarchy's helper sent an unexpected message.")))
        terminate()
    }

    /// `exited` waits until the helper and its output have ended, so a
    /// caller may start again from it.
    private func deliver(_ event: VMRunEvent) {
        let handler = lock.withLock { () -> EventHandler? in
            guard !finished, exitEvent == nil else { return nil }
            if case .exited = event {
                exitEvent = event
                return nil
            }
            return onEvent
        }
        handler?(event)
    }

    private func receiveTermination(_ status: Int32, run: Int) {
        lock.withLock { if self.run == run { terminationStatus = status } }
        finishIfNeeded(force: false, run: run)
    }

    private func finishIfNeeded(force: Bool, run: Int) {
        let result = lock.withLock { () -> (EventHandler, VMRunEvent)? in
            guard self.run == run, !finished, let status = terminationStatus, outputClosed || force else { return nil }
            finished = true
            process = nil
            try? input?.close()
            input = nil
            return (onEvent, exitEvent ?? .exited(status: status))
        }
        guard let (handler, event) = result else { return }
        handler(event)
    }

    private static func status(of process: Process) -> Int32 {
        switch process.terminationReason {
        case .exit: process.terminationStatus
        case .uncaughtSignal: min(255, 128 + process.terminationStatus)
        @unknown default: 1
        }
    }
}
