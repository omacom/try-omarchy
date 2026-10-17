import AVFoundation
import Darwin
import Foundation

enum QEMUGPUStorageOption: String, Equatable {
    case ephemeral = "--ephemeral"
    case resetStorage = "--reset-storage"
    case resetStorageOnly = "--reset-storage-only"
}

/// Build-only controls and user-facing integration values must never leak
/// into an ordinary app launch or a storage reset through the parent process.
enum QEMUGPURuntimeEnvironment {
    static let inspectOnlyKey = "OMARCHY_QEMU_GPU_INSPECT_ONLY"
    static let dryRunKey = "OMARCHY_QEMU_GPU_DRY_RUN"
    /// Where a session-only storage folder clones the decompressed factory from.
    static let factoryCacheKey = "OMARCHY_QEMU_GPU_FACTORY_CACHE"
    /// The downloaded compressed factory, for an app that does not carry it.
    static let factoryImageKey = "OMARCHY_QEMU_GPU_FACTORY_IMAGE"

    static func sanitizedForLaunch(_ base: [String: String]) -> [String: String] {
        var environment = base
        environment.removeValue(forKey: inspectOnlyKey)
        environment.removeValue(forKey: dryRunKey)
        environment.removeValue(forKey: factoryCacheKey)
        environment.removeValue(forKey: factoryImageKey)
        return environment
    }

    static func sanitizedForReset(_ base: [String: String]) -> [String: String] {
        var environment = sanitizedForLaunch(base)
        for key in [
            AudioLaunchConfiguration.inheritedSDLDeviceNameKey,
            AudioLaunchConfiguration.outputDeviceNameKey,
            AudioLaunchConfiguration.inputDeviceNameKey,
            SharedFolderPolicy.environmentKey,
            USBPassthroughPolicy.environmentKey,
            PortForwardPolicy.environmentKey,
            VMResourceLaunchConfiguration.cpuEnvironmentKey,
            VMResourceLaunchConfiguration.memoryEnvironmentKey,
            VMResourceLaunchConfiguration.diskEnvironmentKey,
        ] {
            environment.removeValue(forKey: key)
        }
        for key in VMNetworkPolicy.keys { environment.removeValue(forKey: key) }
        return environment
    }
}

enum QEMUGPUStorageSpaceEstimate {
    private static let stateRootEnvironmentKey = "OMARCHY_QEMU_GPU_STATE_ROOT"

    /// Resolution order is the environment override, then the stored
    /// preference, then Application Support. The override stays first because
    /// it is the documented development and test knob, and the persistent
    /// storage suite drives the whole library through it.
    static func dataDirectoryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        preference: StorageLocationPreference = .default,
        fileManager: FileManager = .default
    ) -> URL? {
        if let configuredRoot = environment[stateRootEnvironmentKey], !configuredRoot.isEmpty {
            return validatedConfiguredRoot(configuredRoot)
        }
        if let container = preference.containerPath {
            return validatedConfiguredRoot(
                StorageLocationPolicy.stateRoot(forContainer: container)
            )
        }
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return applicationSupport
            .appendingPathComponent("Try Omarchy", isDirectory: true)
            .standardizedFileURL
    }

    /// A chosen workspace is the state root itself, exactly as the launcher
    /// script treats `OMARCHY_QEMU_GPU_STATE_ROOT`. Only the default location
    /// carries the historical `VM/v1` suffix.
    static func storageRootURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        preference: StorageLocationPreference = .default,
        fileManager: FileManager = .default
    ) -> URL? {
        if let configuredRoot = environment[stateRootEnvironmentKey], !configuredRoot.isEmpty {
            return validatedConfiguredRoot(configuredRoot)
        }
        if let container = preference.containerPath {
            return validatedConfiguredRoot(
                StorageLocationPolicy.stateRoot(forContainer: container)
            )
        }
        return dataDirectoryURL(environment: environment, fileManager: fileManager)?
            .appendingPathComponent("VM/v1", isDirectory: true)
            .standardizedFileURL
    }

    static func dataDirectoryDisplayPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        preference: StorageLocationPreference = .default,
        fileManager: FileManager = .default
    ) -> String? {
        guard let root = dataDirectoryURL(
            environment: environment,
            preference: preference,
            fileManager: fileManager
        ) else { return nil }
        let path = root.path
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        if path == home {
            return "~"
        }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private static func validatedConfiguredRoot(_ path: String) -> URL? {
        guard path.hasPrefix("/"), !path.contains("\n"), !path.contains("\r") else {
            return nil
        }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let unsafeRoots = ["/", "/Users", "/private", "/private/tmp", "/tmp", "/Volumes"]
        guard !unsafeRoots.contains(root.path) else { return nil }
        return root
    }

    static func formattedReclaimableSpace(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        preference: StorageLocationPreference = .default,
        fileManager: FileManager = .default
    ) -> String? {
        guard let bytes = reclaimableBytes(
            environment: environment,
            preference: preference,
            fileManager: fileManager
        ) else { return nil }
        return format(bytes: bytes)
    }

    /// The space a reset gives back: the VM's own disk and variable store.
    /// The shared factory copy stays for the next VM.
    static func reclaimableBytes(
        environment: [String: String],
        preference: StorageLocationPreference = .default,
        fileManager: FileManager = .default
    ) -> Int64? {
        guard let root = storageRootURL(environment: environment, preference: preference, fileManager: fileManager),
              let disk = persistentDiskURL(stateRoot: root.path, fileManager: fileManager) else { return nil }
        var total: Int64 = 0
        for file in [disk, disk.deletingLastPathComponent().appendingPathComponent("efi-vars.fd")] {
            guard let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]),
                  let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize else { continue }
            total += Int64(allocated)
        }
        return total > 0 ? total : nil
    }

    /// Whether this state root already holds the VM, so launching selects it
    /// instead of creating one from the bundled factory.
    static func hasRecordedPersistentDisk(stateRoot: String, fileManager: FileManager = .default) -> Bool {
        persistentDiskURL(stateRoot: stateRoot, fileManager: fileManager) != nil
    }

    /// The launcher keeps the VM's disk at `shell/disk.img`, beside its UEFI
    /// variable store, with the decompressed factory in `shell-factory/`.
    static func persistentDiskURL(stateRoot: String, fileManager: FileManager = .default) -> URL? {
        let disk = URL(fileURLWithPath: stateRoot, isDirectory: true)
            .appendingPathComponent("shell/disk.img", isDirectory: false)
        return hasAttributes(disk, type: .typeRegular, permissions: 0o600, fileManager: fileManager) ? disk : nil
    }

    static func format(bytes: Int64) -> String? {
        guard bytes > 0 else { return nil }
        let gigabytes = Double(bytes) / 1_000_000_000
        if gigabytes < 0.1 {
            return "less than 0.1 GB"
        }
        return String(format: "%.1f GB", gigabytes)
    }

    static func bundledIdentity(bundle: Bundle = .main) -> String? {
        bundledMetrics(bundle: bundle)?.identity
    }

    /// Reads the factory identity and disk size from `Resources/guest/factory.json`.
    /// The sizes drive the free-space guard, so a manifest missing either one
    /// yields nil rather than a guess.
    static func bundledMetrics(bundle: Bundle = .main) -> BundledGuestMetrics? {
        guard let resourceURL = bundle.resourceURL,
              let data = try? Data(contentsOf: resourceURL.appendingPathComponent("guest/factory.json")),
              var metrics = factoryMetrics(data) else { return nil }
        if !bundlesFactoryImage(bundle: bundle),
           let manifest = FactoryDownloadManifest.bundled(bundle: bundle),
           manifest.identity == metrics.identity {
            metrics.downloadBytes = manifest.imageBytes
        }
        return metrics
    }

    /// Development builds carry the compressed factory; release builds
    /// download it (FactoryImageDownload.swift).
    static func bundlesFactoryImage(bundle: Bundle = .main) -> Bool {
        guard let resourceURL = bundle.resourceURL,
              let data = try? Data(contentsOf: resourceURL.appendingPathComponent("guest/factory.json")),
              data.count <= 65_536,
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let compressed = manifest["compressed"] as? [String: Any],
              let name = compressed["path"] as? String,
              !name.isEmpty, !name.contains("/") else { return false }
        return FactoryImageStore.isRegularFile(resourceURL.appendingPathComponent("guest/\(name)"))
    }

    static func factoryMetrics(_ data: Data) -> BundledGuestMetrics? {
        guard data.count <= 65_536,
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              manifest["kind"] as? String == "upstream-shell-factory",
              (manifest["format"] as? NSNumber)?.intValue == 1,
              let disk = manifest["disk"] as? [String: Any],
              let identity = disk["sha256"] as? String,
              isIdentity(identity),
              let bytes = (disk["bytes"] as? NSNumber)?.int64Value,
              bytes > 0 else { return nil }
        // The launcher writes about half of the sparse factory disk when it
        // first decompresses it (run-qemu-gpu.sh prepare_factory_disk).
        return BundledGuestMetrics(identity: identity, sourceDiskBytes: bytes / 2, workingDiskBytes: bytes)
    }

    private static func hasAttributes(
        _ url: URL,
        type: FileAttributeType,
        permissions: Int,
        fileManager: FileManager
    ) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
              values.isSymbolicLink != true,
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == type,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == permissions
        else { return false }
        return true
    }

    private static func isIdentity(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}

struct QEMUGPULaunchRequest: Equatable {
    let storageOption: QEMUGPUStorageOption?
    let guestDirectoryPath: String?

    init(
        storageOption: QEMUGPUStorageOption?,
        guestDirectoryPath: String?
    ) {
        self.storageOption = storageOption
        self.guestDirectoryPath = guestDirectoryPath
    }

    init?(arguments: [String]) {
        var remaining = arguments[...]
        var storageOption: QEMUGPUStorageOption?

        if let first = remaining.first,
           let parsedOption = QEMUGPUStorageOption(rawValue: first) {
            storageOption = parsedOption
            remaining = remaining.dropFirst()
        }

        guard remaining.count <= 1 else { return nil }
        let guestDirectoryPath = remaining.first
        if let guestDirectoryPath {
            guard guestDirectoryPath.hasPrefix("/"),
                  !guestDirectoryPath.hasPrefix("--"),
                  !guestDirectoryPath.contains("\n"),
                  !guestDirectoryPath.contains("\r") else { return nil }
        }

        self.storageOption = storageOption
        self.guestDirectoryPath = guestDirectoryPath
    }

    func validatedScriptArguments() throws -> [String] {
        var result = storageOption.map { [$0.rawValue] } ?? []
        guard let guestDirectoryPath else { return result }

        let guestDirectory = URL(
            fileURLWithPath: guestDirectoryPath,
            isDirectory: true
        ).standardizedFileURL
        var information = stat()
        guard Darwin.lstat(guestDirectory.path, &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR else {
            throw HelperError.io("ARM guest directory is missing or unsafe: \(guestDirectory.path)")
        }

        let canonicalDirectory = guestDirectory.resolvingSymlinksInPath()
        result.append(canonicalDirectory.path)
        return result
    }

}

enum QEMUGPULauncherPath {
    static let appName = "Try Omarchy.app"
    static let launcherName = "run-qemu-gpu.sh"

    static func resolve(bundleURL: URL) throws -> URL {
        let standardizedBundle = bundleURL.standardizedFileURL
        var bundleInformation = stat()
        guard standardizedBundle.lastPathComponent == appName,
              Darwin.lstat(standardizedBundle.path, &bundleInformation) == 0,
              bundleInformation.st_mode & S_IFMT == S_IFDIR else {
            throw HelperError.io("QEMU launch is available only from the built Omarchy app")
        }

        let canonicalBundle = standardizedBundle.resolvingSymlinksInPath()
        let resources = canonicalBundle
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        let scripts = resources.appendingPathComponent("scripts", isDirectory: true)
        let launcher = scripts.appendingPathComponent(launcherName, isDirectory: false)
        let canonicalLauncher = launcher.resolvingSymlinksInPath()
        var launcherInformation = stat()
        guard canonicalLauncher.deletingLastPathComponent() == scripts,
              Darwin.lstat(launcher.path, &launcherInformation) == 0,
              launcherInformation.st_mode & S_IFMT == S_IFREG,
              FileManager.default.isExecutableFile(atPath: launcher.path) else {
            throw HelperError.io("bundled QEMU launcher is missing or unsafe: \(launcher.path)")
        }
        return canonicalLauncher
    }
}

enum MicrophoneAuthorizationState: Equatable {
    case authorized
    case denied
    case restricted
    case notDetermined
}

enum CameraAuthorizationState: Equatable {
    case authorized
    case denied
    case restricted
    case notDetermined
}

enum AccessibilityAuthorizationState: Equatable {
    case authorized
    case unavailable
}

struct AccessibilityLaunchDecision: Equatable {
    let allowsLaunch: Bool
    let warning: String?

    static func make(for state: AccessibilityAuthorizationState) -> Self {
        switch state {
        case .authorized:
            Self(allowsLaunch: true, warning: nil)
        case .unavailable:
            Self(
                allowsLaunch: true,
                warning: "Accessibility is not active yet; Omarchy will start without Command-to-Super mapping. The mapping becomes available on a later launch after macOS recognizes the grant."
            )
        }
    }
}

struct MicrophoneLaunchDecision: Equatable {
    let allowsLaunch: Bool
    let warning: String?

    static func make(for state: MicrophoneAuthorizationState) -> Self {
        switch state {
        case .authorized:
            Self(allowsLaunch: true, warning: nil)
        case .denied:
            Self(
                allowsLaunch: true,
                warning: "Microphone access is denied. Audio playback will continue, but guest recording is unavailable. Enable Try Omarchy in System Settings > Privacy & Security > Microphone, then relaunch."
            )
        case .restricted:
            Self(
                allowsLaunch: true,
                warning: "Microphone access is restricted by macOS policy. Audio playback will continue, but guest recording is unavailable. Ask the Mac administrator to allow microphone access for Try Omarchy."
            )
        case .notDetermined:
            Self(
                allowsLaunch: true,
                warning: "Microphone access was not requested. Audio playback will continue, but guest recording is unavailable until access is enabled."
            )
        }
    }
}

struct CameraLaunchDecision: Equatable {
    let allowsLaunch: Bool
    let warning: String?

    static func make(for state: CameraAuthorizationState) -> Self {
        switch state {
        case .authorized:
            Self(allowsLaunch: true, warning: nil)
        case .denied:
            Self(
                allowsLaunch: true,
                warning: "Camera access is denied. Omarchy will continue without the Mac camera. Enable Try Omarchy in System Settings > Privacy & Security > Camera, then relaunch."
            )
        case .restricted:
            Self(
                allowsLaunch: true,
                warning: "Camera access is restricted by macOS policy. Omarchy will continue without the Mac camera. Ask the Mac administrator to allow camera access for Try Omarchy."
            )
        case .notDetermined:
            Self(
                allowsLaunch: true,
                warning: "Camera access was not requested. Omarchy will continue without the Mac camera until access is enabled."
            )
        }
    }
}

enum MicrophonePreflight {
    static func authorizationState() -> MicrophoneAuthorizationState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .restricted
        }
    }

    static func requestAccess(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }

    static func decision() -> MicrophoneLaunchDecision {
        .make(for: authorizationState())
    }
}

enum CameraPreflight {
    static func authorizationState() -> CameraAuthorizationState {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .restricted
        }
    }

    static func requestAccess(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video, completionHandler: completion)
    }

    static func decision() -> CameraLaunchDecision {
        .make(for: authorizationState())
    }
}

final class QEMUGPUProcessSupervisor: @unchecked Sendable {
    enum LaunchEvent: Equatable {
        case virtualMachineReady(qmpSocketPath: String?)
        case resetProgress(VMResetPhase)
        case launchProgress(VMLaunchPhase)
    }

    struct StandardErrorDrain {
        let data: Data
        let reachedEnd: Bool
    }

    private struct StandardErrorConsumption {
        let reachedEnd: Bool
        let launchEvents: [LaunchEvent]
    }

    private static let standardErrorReadBudget = 64 * 1_024

    private let lock = NSLock()
    private let standardErrorReadLock = NSLock()
    private var child: Process?
    private var errorPipe: Pipe?
    private var errorBuffer = ""
    private var didReportVirtualMachineStart = false
    private var resetProgressStream: VMProgressStream<VMResetPhase>?
    private var launchProgressStream: VMProgressStream<VMLaunchPhase>?

    func start(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        launchEvent: @escaping @MainActor @Sendable (LaunchEvent) -> Void = { _ in },
        completion: @escaping @MainActor @Sendable (Int32) -> Void
    ) throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else {
                handle.readabilityHandler = nil
                return
            }
            let consumption = self.consumeAvailableStandardError(from: handle)
            if consumption.reachedEnd {
                handle.readabilityHandler = nil
            }
            if !consumption.launchEvents.isEmpty {
                DispatchQueue.main.async {
                    for event in consumption.launchEvents {
                        launchEvent(event)
                    }
                }
            }
        }
        process.terminationHandler = { [weak self] process in
            pipe.fileHandleForReading.readabilityHandler = nil
            // QEMU inherits this pipe from the shell launcher and can outlive
            // it after a crash. Drain only bytes available now; waiting for
            // EOF here could strand process completion for the QEMU lifetime.
            let finalEvents = self?.consumeAvailableStandardError(
                from: pipe.fileHandleForReading
            ).launchEvents ?? []
            if !finalEvents.isEmpty {
                DispatchQueue.main.async {
                    for event in finalEvents {
                        launchEvent(event)
                    }
                }
            }
            self?.clear(process)
            let status = Self.status(for: process)
            // NSApplication owns a synchronous AppKit run loop. Dispatching a
            // main-queue block lets that run loop service child completion;
            // a MainActor Task could wait behind the still-running call.
            DispatchQueue.main.async {
                completion(status)
            }
        }

        lock.lock()
        guard child == nil else {
            lock.unlock()
            throw HelperError.io("QEMU launcher process is already running")
        }
        child = process
        errorPipe = pipe
        errorBuffer = ""
        didReportVirtualMachineStart = false
        let isReset = arguments.first == QEMUGPUStorageOption.resetStorageOnly.rawValue
        resetProgressStream = isReset ? VMProgressStream(operation: .reset) : nil
        launchProgressStream = isReset ? nil : VMProgressStream(operation: .launch)
        lock.unlock()

        do {
            try process.run()
        } catch {
            clear(process)
            throw error
        }
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return child?.isRunning == true
    }

    var recentStandardError: String {
        lock.lock()
        defer { lock.unlock() }
        return errorBuffer
    }

    func forward(signal: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard let child, child.isRunning else { return }
        _ = Darwin.kill(child.processIdentifier, signal)
    }

    private func clear(_ process: Process) {
        lock.lock()
        if child === process {
            child = nil
            errorPipe?.fileHandleForReading.readabilityHandler = nil
            errorPipe = nil
        }
        lock.unlock()
    }

    private func consumeAvailableStandardError(
        from handle: FileHandle
    ) -> StandardErrorConsumption {
        standardErrorReadLock.lock()
        defer { standardErrorReadLock.unlock() }

        let drain = Self.drainAvailableStandardError(
            from: handle,
            maximumBytes: Self.standardErrorReadBudget
        )
        guard !drain.data.isEmpty else {
            return StandardErrorConsumption(
                reachedEnd: drain.reachedEnd,
                launchEvents: []
            )
        }
        try? FileHandle.standardError.write(contentsOf: drain.data)
        return StandardErrorConsumption(
            reachedEnd: drain.reachedEnd,
            launchEvents: recordStandardError(drain.data)
        )
    }

    static func drainAvailableStandardError(
        from handle: FileHandle,
        maximumBytes: Int
    ) -> StandardErrorDrain {
        guard maximumBytes > 0 else {
            return StandardErrorDrain(data: Data(), reachedEnd: false)
        }

        let descriptor = handle.fileDescriptor
        let originalFlags = fileStatusFlags(for: descriptor)
        guard originalFlags >= 0 else {
            return StandardErrorDrain(data: Data(), reachedEnd: false)
        }

        let changedFlags = originalFlags & O_NONBLOCK == 0
        if changedFlags,
           !setFileStatusFlags(originalFlags | O_NONBLOCK, for: descriptor) {
            return StandardErrorDrain(data: Data(), reachedEnd: false)
        }
        defer {
            if changedFlags {
                _ = setFileStatusFlags(originalFlags, for: descriptor)
            }
        }

        var data = Data()
        var reachedEnd = false
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while data.count < maximumBytes {
            let requestedBytes = min(buffer.count, maximumBytes - data.count)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, requestedBytes)
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 {
                reachedEnd = true
                break
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            }
            break
        }
        return StandardErrorDrain(data: data, reachedEnd: reachedEnd)
    }

    private static func fileStatusFlags(for descriptor: Int32) -> Int32 {
        while true {
            let result = Darwin.fcntl(descriptor, F_GETFL)
            if result >= 0 || errno != EINTR {
                return result
            }
        }
    }

    private static func setFileStatusFlags(_ flags: Int32, for descriptor: Int32) -> Bool {
        while true {
            let result = Darwin.fcntl(descriptor, F_SETFL, flags)
            if result >= 0 {
                return true
            }
            if errno != EINTR {
                return false
            }
        }
    }

    private func recordStandardError(_ data: Data) -> [LaunchEvent] {
        lock.lock()
        defer { lock.unlock() }
        errorBuffer += String(decoding: data, as: UTF8.self)
        var launchEvents = (resetProgressStream?.append(data) ?? []).map(LaunchEvent.resetProgress)
        launchEvents += (launchProgressStream?.append(data) ?? []).map(LaunchEvent.launchProgress)
        if !didReportVirtualMachineStart,
           let event = Self.virtualMachineReadyEvent(in: errorBuffer) {
            didReportVirtualMachineStart = true
            launchEvents.append(event)
        }
        if errorBuffer.count > 4_096 {
            errorBuffer = String(errorBuffer.suffix(4_096))
        }
        return launchEvents
    }

    /// Extracts only a complete launcher-owned readiness line. Waiting for its
    /// newline matters because FileHandle can split the socket pathname across
    /// arbitrary readability callbacks.
    static func virtualMachineReadyEvent(in standardError: String) -> LaunchEvent? {
        let marker = "[qemu-gpu] Ready. QMP: "
        var lineStart = standardError.startIndex
        while let newline = standardError[lineStart...].firstIndex(of: "\n") {
            var line = String(standardError[lineStart..<newline])
            if line.last == "\r" {
                line.removeLast()
            }
            if line.hasPrefix(marker) {
                return .virtualMachineReady(
                    qmpSocketPath: qmpSocketPath(inReadyLine: line)
                )
            }
            lineStart = standardError.index(after: newline)
        }
        return nil
    }

    static func qmpSocketPath(inReadyLine line: String) -> String? {
        let linePrefix = "[qemu-gpu] Ready. QMP: "
        guard line.hasPrefix(linePrefix) else { return nil }
        let path = String(line.dropFirst(linePrefix.count))
        let pathPrefix = "/tmp/omarchy-qemu-gpu."
        let pathSuffix = "/qmp.sock"
        guard path.hasPrefix(pathPrefix), path.hasSuffix(pathSuffix) else { return nil }
        let token = path
            .dropFirst(pathPrefix.count)
            .dropLast(pathSuffix.count)
        guard token.count == 6,
              token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        return path
    }

    private static func status(for process: Process) -> Int32 {
        switch process.terminationReason {
        case .exit:
            return process.terminationStatus
        case .uncaughtSignal:
            return 128 + process.terminationStatus
        @unknown default:
            return 1
        }
    }
}
