import CryptoKit
import Darwin
import Foundation

/// The compressed factory image a release app downloads on first use instead
/// of carrying it (`Resources/guest/download.json`, written by build-app.sh).
/// GitHub release assets must stay under 2 GiB, so the image is published in
/// parts: consecutive byte ranges of the image, each with its own digest.
struct FactoryDownloadManifest: Equatable {
    struct Part: Equatable {
        let url: URL
        let offset: Int64
        let bytes: Int64
        let sha256: String

        var end: Int64 { offset + bytes }
    }

    static let fileName = "download.json"

    /// The factory disk's digest, as in factory.json.
    let identity: String
    let imageBytes: Int64
    let imageSHA256: String
    let parts: [Part]

    static func bundled(bundle: Bundle = .main) -> Self? {
        guard let resourceURL = bundle.resourceURL,
              let data = try? Data(contentsOf: resourceURL.appendingPathComponent("guest/\(fileName)"))
        else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> Self? {
        guard data.count <= 65_536,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.format == 1, payload.kind == "try-omarchy-factory-download",
              isDigest(payload.identity), isDigest(payload.image.sha256), payload.image.bytes > 0,
              (1...64).contains(payload.parts.count) else { return nil }
        var offset: Int64 = 0
        var parts: [Part] = []
        for part in payload.parts {
            guard part.bytes > 0, isDigest(part.sha256),
                  let url = URL(string: part.url), isAllowed(url) else { return nil }
            parts.append(Part(url: url, offset: offset, bytes: part.bytes, sha256: part.sha256))
            let (next, overflow) = offset.addingReportingOverflow(part.bytes)
            guard !overflow else { return nil }
            offset = next
        }
        guard offset == payload.image.bytes else { return nil }
        return Self(identity: payload.identity, imageBytes: payload.image.bytes,
                    imageSHA256: payload.image.sha256, parts: parts)
    }

    /// HTTPS, or plain HTTP to this Mac for testing a release build locally.
    private static func isAllowed(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, let host = url.host, !host.isEmpty else { return false }
        switch url.scheme {
        case "https": return true
        case "http": return host == "127.0.0.1" || host == "localhost"
        default: return false
        }
    }

    private struct Payload: Decodable {
        let format: Int
        let kind: String
        let identity: String
        let image: Image
        let parts: [PartPayload]

        struct Image: Decodable {
            let bytes: Int64
            let sha256: String
        }

        struct PartPayload: Decodable {
            let url: String
            let bytes: Int64
            let sha256: String
        }
    }
}

private func isDigest(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
}

/// Where the launcher finds the compressed factory, and whether this launch
/// must download it first. Only a new VM disk needs the factory, and only when
/// no decompressed copy exists to clone (run-qemu-gpu.sh prepare_factory_disk).
enum FactoryImagePreparation: Equatable {
    case ready(image: URL?)
    case download(directory: URL)

    static func plan(
        manifest: FactoryDownloadManifest?,
        bundlesImage: Bool,
        stateRoot: URL,
        sharedFactory: URL?,
        fileManager: FileManager = .default
    ) -> Self {
        guard let manifest, !bundlesImage else { return .ready(image: nil) }
        let localFactory = stateRoot.appendingPathComponent(VMWorkspaceTransfer.factoryCacheName, isDirectory: true)
        let directory = sharedFactory ?? localFactory
        let image = FactoryImageStore.imageURL(in: directory, identity: manifest.identity)
        let needsNewDisk = !FactoryImageStore.isRegularFile(
            stateRoot.appendingPathComponent("shell/disk.img"), fileManager: fileManager)
        let factoryReady = [localFactory, sharedFactory].contains { cache in
            cache.map {
                FactoryImageStore.isRegularFile(
                    FactoryImageStore.factoryDiskURL(in: $0, identity: manifest.identity), fileManager: fileManager)
            } ?? false
        }
        if needsNewDisk && !factoryReady { return .download(directory: directory) }
        return .ready(image: FactoryImageStore.isRegularFile(image, fileManager: fileManager) ? image : nil)
    }
}

/// The downloaded image lives beside the decompressed factory it becomes, in
/// the storage folder's `shell-factory/`: `<identity>.img.zst` once verified,
/// `<identity>.img.zst.download` while it is being fetched.
enum FactoryImageStore {
    static func imageURL(in directory: URL, identity: String) -> URL {
        directory.appendingPathComponent("\(identity).img.zst", isDirectory: false)
    }

    static func partialURL(in directory: URL, identity: String) -> URL {
        directory.appendingPathComponent("\(identity).img.zst.download", isDirectory: false)
    }

    static func factoryDiskURL(in directory: URL, identity: String) -> URL {
        directory.appendingPathComponent("\(identity).img", isDirectory: false)
    }

    static func isRegularFile(_ url: URL, fileManager: FileManager = .default) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeRegular
    }

    /// Creates `shell-factory/` the way the launcher would. The storage folder
    /// gets its marker first, so a folder the user picked is never left holding
    /// files without being recognizable as a workspace. `mayCreateRoot` is
    /// false for a chosen folder: one that has gone missing (an unplugged
    /// drive) must not be recreated under /Volumes.
    static func prepareDirectory(_ directory: URL, mayCreateRoot: Bool, fileManager: FileManager = .default) throws {
        let root = directory.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) {
            guard mayCreateRoot else {
                throw FactoryDownloadError.storage("the Omarchy data folder is unavailable: \(root.path)")
            }
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        } else if !isDirectory.boolValue {
            throw FactoryDownloadError.storage("the Omarchy data folder is not a folder: \(root.path)")
        }
        let marker = root.appendingPathComponent(StorageLocationPolicy.rootMarkerName, isDirectory: false)
        let descriptor = Darwin.open(marker.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if descriptor >= 0 {
            let content = StorageLocationPolicy.rootMarkerContent + "\n"
            let written = content.withCString { Darwin.write(descriptor, $0, strlen($0)) }
            Darwin.close(descriptor)
            guard written == content.utf8.count else {
                throw FactoryDownloadError.storage("could not mark the Omarchy data folder")
            }
        } else if errno != EEXIST {
            throw FactoryDownloadError.storage("could not mark the Omarchy data folder (\(String(cString: strerror(errno))))")
        }
        guard StorageLocationPolicy.hasValidRootMarker(in: root) else {
            throw FactoryDownloadError.storage("the Omarchy data folder has an invalid marker: \(marker.path)")
        }
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
        }
    }

    /// Removes downloads for other factories, and this factory's download once
    /// its decompressed copy exists. Skipped while another app instance holds
    /// the folder for a download.
    static func removeObsoleteDownloads(in directory: URL, identity: String, fileManager: FileManager = .default) {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return }
        defer { flock(descriptor, LOCK_UN) }
        let factoryReady = isRegularFile(factoryDiskURL(in: directory, identity: identity), fileManager: fileManager)
        for name in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [] {
            let owner: Substring
            if name.hasSuffix(".img.zst") {
                owner = name.dropLast(".img.zst".count)
            } else if name.hasSuffix(".img.zst.download") {
                owner = name.dropLast(".img.zst.download".count)
            } else {
                continue
            }
            guard isDigest(String(owner)), owner != identity || factoryReady else { continue }
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}

struct FactoryDownloadProgress: Equatable {
    enum Phase: Equatable {
        case waiting
        case downloading
        case retrying
        case verifying
    }

    var phase: Phase
    var completedBytes: Int64
    var totalBytes: Int64

    var percent: Int {
        guard totalBytes > 0 else { return 0 }
        return Int(min(100, max(0, completedBytes * 100 / totalBytes)))
    }

    var title: String {
        switch phase {
        case .waiting: "Waiting for another download…"
        case .downloading: "Downloading Omarchy… \(percent)% of \(StorageLocationPolicy.format(bytes: totalBytes))"
        case .retrying: "Reconnecting… \(percent)% downloaded"
        case .verifying: "Verifying download…"
        }
    }
}

enum FactoryDownloadError: LocalizedError, Equatable {
    case unavailable(statusCode: Int)
    case connection(String)
    case damaged
    case insufficientSpace(needed: Int64, available: Int64)
    /// The volume filled up during the download, from it or from anything else.
    case diskFull(downloaded: Int64)
    case storage(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unavailable(let statusCode):
            "The Omarchy image is not available for download (the server answered HTTP \(statusCode)). Check for a newer version of Try Omarchy."
        case .connection(let detail):
            "Omarchy could not be downloaded: \(detail) Check your internet connection, then choose Launch Omarchy to continue the download where it stopped."
        case .damaged:
            "The downloaded Omarchy image did not match its checksum. Choose Launch Omarchy to download it again."
        case .insufficientSpace(let needed, let available):
            "There is not enough free space to download and prepare Omarchy: \(StorageLocationPolicy.format(bytes: needed)) needed, \(StorageLocationPolicy.format(bytes: available)) available."
        case .diskFull(let downloaded):
            "Your Mac is running out of disk space, so the Omarchy download stopped. The \(StorageLocationPolicy.format(bytes: downloaded)) already downloaded is kept. Free up some space, then choose Launch Omarchy to continue."
        case .storage(let detail):
            "Omarchy could not be downloaded: \(detail)."
        case .cancelled:
            "The download was cancelled."
        }
    }
}

/// Downloads the factory image into one file, resumably and verifiably.
///
/// Each part is fetched with an HTTP range request that starts where the file
/// ends, so an interrupted download (a dropped connection, sleep, quitting
/// the app) continues from the last byte written. Every part is checked
/// against its digest once complete, including parts already on disk when a
/// download resumes; a damaged part is truncated away and fetched again. The
/// image is renamed into place only after the whole-image digest matches.
final class FactoryImageDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Policy {
        /// Waits between attempts that made no progress; one more failure
        /// than there are delays ends the download.
        var retryDelays: [TimeInterval] = [1, 2, 4, 8, 15, 30, 30, 30]
        var damagedPartAttempts = 3
        /// A connection that delivers nothing for this long is retried.
        var requestTimeout: TimeInterval = 30
        var progressInterval: TimeInterval = 0.1
        /// How often the free space is checked while bytes arrive.
        var spaceCheckBytes: Int64 = 128 << 20
        /// The download stops before the volume has less than this left, so
        /// it never fills the Mac's disk even if something else is using space.
        var minimumFreeBytes: Int64 = StorageSpaceRequirement.headroomBytes
        var lockPollInterval: TimeInterval = 0.5
    }

    let manifest: FactoryDownloadManifest
    let directory: URL
    /// Free space that must remain after the download, for decompressing it.
    let reserveBytes: Int64
    private let policy: Policy
    private let configuration: URLSessionConfiguration
    private let freeBytes: (URL) -> Int64?

    private let stateLock = NSLock()
    private var isCancelled = false
    private var activeTask: URLSessionDataTask?
    private let wake = DispatchSemaphore(value: 0)

    // Owned by the delegate queue while a request runs, then by `run`.
    private var transfer: Transfer?
    private var descriptor: Int32 = -1
    private var reportProgress: (FactoryDownloadProgress) -> Void = { _ in }
    private var lastReport = Date.distantPast
    private var nextSpaceCheck: Int64 = 0

    var imageURL: URL { FactoryImageStore.imageURL(in: directory, identity: manifest.identity) }
    var partialURL: URL { FactoryImageStore.partialURL(in: directory, identity: manifest.identity) }

    init(
        manifest: FactoryDownloadManifest,
        directory: URL,
        reserveBytes: Int64,
        policy: Policy = Policy(),
        configuration: URLSessionConfiguration = .default,
        freeBytes: @escaping (URL) -> Int64? = FactoryImageDownloader.availableBytes
    ) {
        self.manifest = manifest
        self.directory = directory
        self.reserveBytes = reserveBytes
        self.policy = policy
        self.configuration = configuration
        self.freeBytes = freeBytes
    }

    /// Thread-safe. The running download stops with `.cancelled`; what it
    /// wrote so far is kept for the next attempt.
    func cancel() {
        stateLock.lock()
        isCancelled = true
        let task = activeTask
        stateLock.unlock()
        task?.cancel()
        wake.signal()
    }

    /// Blocks until the verified image is in place and returns it.
    func run(progress: @escaping (FactoryDownloadProgress) -> Void) throws -> URL {
        reportProgress = progress
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Downloading the Omarchy image")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        let directoryDescriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directoryDescriptor >= 0 else { throw storageError("could not open \(directory.path)") }
        defer { Darwin.close(directoryDescriptor) }
        // Another instance (a disposable VM beside the persistent one) may be
        // downloading the same image; wait for it and use its result.
        while flock(directoryDescriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw storageError("could not lock \(directory.path)") }
            let size = (try? FileManager.default.attributesOfItem(atPath: partialURL.path))?[.size] as? NSNumber
            report(.waiting, completed: size?.int64Value ?? 0, force: true)
            try pause(policy.lockPollInterval)
        }
        defer { flock(directoryDescriptor, LOCK_UN) }

        if FactoryImageStore.isRegularFile(imageURL) {
            if try verifyExistingImage() { return imageURL }
            try? FileManager.default.removeItem(at: imageURL)
        }

        descriptor = Darwin.open(partialURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw storageError("could not create \(partialURL.path)") }
        defer {
            Darwin.close(descriptor)
            descriptor = -1
        }
        if try fileSize() > manifest.imageBytes { try truncate(to: 0) }

        // Parts already on disk are checked before anything is appended, so a
        // file damaged while the app was not running is repaired, not extended.
        var whole = SHA256()
        var index = 0
        while index < manifest.parts.count, manifest.parts[index].end <= (try fileSize()) {
            let part = manifest.parts[index]
            report(.verifying, completed: part.offset, force: true)
            var candidate = whole
            if try hash(part, into: &candidate) {
                whole = candidate
                index += 1
            } else {
                try truncate(to: part.offset)
            }
        }

        let remaining = manifest.imageBytes - (try fileSize())
        if let available = freeBytes(directory), available < remaining + reserveBytes {
            throw FactoryDownloadError.insufficientSpace(needed: remaining + reserveBytes, available: available)
        }

        let session = URLSession(configuration: sessionConfiguration(), delegate: self, delegateQueue: delegateQueue())
        defer { session.invalidateAndCancel() }
        var failuresWithoutProgress = 0
        var damagedAttempts = 0
        while index < manifest.parts.count {
            try checkCancelled()
            let part = manifest.parts[index]
            let start = try fileSize()
            if start < part.end {
                report(.downloading, completed: start, force: true)
                let result = try fetch(part, from: start, session: session)
                if try fileSize() > start { failuresWithoutProgress = 0 }
                switch result {
                case .finished:
                    break
                case .restartPart(let reason):
                    try truncate(to: part.offset)
                    try retry(after: &failuresWithoutProgress, reason: reason)
                    continue
                case .retry(let reason):
                    try retry(after: &failuresWithoutProgress, reason: reason)
                    continue
                }
                guard try fileSize() == part.end else {
                    try retry(after: &failuresWithoutProgress, reason: "The connection closed early.")
                    continue
                }
            }
            report(.verifying, completed: part.end, force: true)
            var candidate = whole
            if try hash(part, into: &candidate) {
                whole = candidate
                index += 1
                damagedAttempts = 0
            } else {
                try truncate(to: part.offset)
                damagedAttempts += 1
                fputs("[download] part \(index + 1) did not match its digest (attempt \(damagedAttempts))\n", stderr)
                guard damagedAttempts < policy.damagedPartAttempts else { throw FactoryDownloadError.damaged }
            }
        }

        guard Self.hex(whole.finalize()) == manifest.imageSHA256 else {
            try truncate(to: 0)
            throw FactoryDownloadError.damaged
        }
        guard fsync(descriptor) == 0 else {
            if errno == ENOSPC { throw FactoryDownloadError.diskFull(downloaded: manifest.imageBytes) }
            throw storageError("could not save the download")
        }
        guard Darwin.rename(partialURL.path, imageURL.path) == 0 else {
            throw storageError("could not finish the download")
        }
        _ = fsync(directoryDescriptor)
        return imageURL
    }

    static func availableBytes(at url: URL) -> Int64? {
        var information = statfs()
        guard statfs(url.path, &information) == 0 else { return nil }
        return Int64(information.f_bavail) * Int64(information.f_bsize)
    }

    // MARK: - Requests

    private enum FetchResult {
        case finished
        case retry(String)
        case restartPart(String)
    }

    private final class Transfer {
        let part: FactoryDownloadManifest.Part
        var position: Int64
        var result: FetchResult = .finished
        var failure: FactoryDownloadError?
        var decided = false
        let done = DispatchSemaphore(value: 0)

        init(part: FactoryDownloadManifest.Part, position: Int64) {
            self.part = part
            self.position = position
        }

        func decide(_ result: FetchResult) {
            guard !decided else { return }
            decided = true
            self.result = result
        }

        func fail(_ failure: FactoryDownloadError) {
            guard !decided else { return }
            decided = true
            self.failure = failure
        }
    }

    private func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = self.configuration.copy() as! URLSessionConfiguration
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = policy.requestTimeout
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        configuration.waitsForConnectivity = false
        return configuration
    }

    private func delegateQueue() -> OperationQueue {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "Try Omarchy factory download"
        return queue
    }

    private func fetch(_ part: FactoryDownloadManifest.Part, from start: Int64, session: URLSession) throws -> FetchResult {
        var request = URLRequest(url: part.url)
        request.setValue("bytes=\(start - part.offset)-\(part.bytes - 1)", forHTTPHeaderField: "Range")
        // Ranges must count the stored bytes, never a re-encoded body.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let transfer = Transfer(part: part, position: start)
        self.transfer = transfer
        let task = session.dataTask(with: request)
        stateLock.lock()
        let cancelled = isCancelled
        if !cancelled { activeTask = task }
        stateLock.unlock()
        if cancelled { throw FactoryDownloadError.cancelled }
        task.resume()
        transfer.done.wait()
        stateLock.lock()
        activeTask = nil
        stateLock.unlock()
        self.transfer = nil
        try checkCancelled()
        if let failure = transfer.failure { throw failure }
        return transfer.result
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let transfer, let response = response as? HTTPURLResponse else {
            self.transfer?.decide(.retry("The server sent an invalid response."))
            completionHandler(.cancel)
            return
        }
        let part = transfer.part
        switch response.statusCode {
        case 206:
            let range = ContentRange(response.value(forHTTPHeaderField: "Content-Range"))
            guard let range, range.first == transfer.position - part.offset,
                  range.last == part.bytes - 1, range.total == nil || range.total == part.bytes else {
                transfer.decide(.restartPart("The server sent a different part of the image."))
                completionHandler(.cancel)
                return
            }
        case 200:
            // The server ignored the range and sends the whole part.
            guard response.expectedContentLength < 0 || response.expectedContentLength == part.bytes else {
                transfer.decide(.retry("The server sent a file of the wrong size."))
                completionHandler(.cancel)
                return
            }
            if transfer.position != part.offset {
                do { try truncate(to: part.offset) } catch {
                    transfer.fail(error as? FactoryDownloadError ?? .storage(error.localizedDescription))
                    completionHandler(.cancel)
                    return
                }
                transfer.position = part.offset
            }
        case 416:
            transfer.decide(.restartPart("The server could not resume the download."))
            completionHandler(.cancel)
            return
        case 408, 429, 500...599:
            transfer.decide(.retry("The server is busy (HTTP \(response.statusCode))."))
            completionHandler(.cancel)
            return
        default:
            transfer.fail(.unavailable(statusCode: response.statusCode))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let transfer, !transfer.decided else { return }
        let room = transfer.part.end - transfer.position
        let count = Int(min(Int64(data.count), room))
        if count > 0 {
            let written = data.withUnsafeBytes { buffer -> Bool in
                var offset = 0
                while offset < count {
                    let result = pwrite(descriptor, buffer.baseAddress! + offset, count - offset,
                                        off_t(transfer.position) + off_t(offset))
                    if result < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    offset += result
                }
                return true
            }
            guard written else {
                transfer.fail(errno == ENOSPC || errno == EDQUOT
                    ? .diskFull(downloaded: transfer.position)
                    : .storage("could not write the download (\(String(cString: strerror(errno))))"))
                dataTask.cancel()
                return
            }
            transfer.position += Int64(count)
            report(.downloading, completed: transfer.position)
            if transfer.position >= nextSpaceCheck {
                nextSpaceCheck = transfer.position + policy.spaceCheckBytes
                let remaining = manifest.imageBytes - transfer.position
                if let available = freeBytes(directory), available < remaining + policy.minimumFreeBytes {
                    transfer.fail(.diskFull(downloaded: transfer.position))
                    dataTask.cancel()
                    return
                }
            }
        }
        if data.count > count {
            // More than the part: keep what fits and let its digest decide.
            transfer.decide(.finished)
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let transfer else { return }
        if let error {
            let description = (error as? URLError)?.localizedDescription ?? error.localizedDescription
            transfer.decide(.retry(description.hasSuffix(".") ? description : description + "."))
        } else {
            transfer.decide(.finished)
        }
        transfer.done.signal()
    }

    /// Keeps the Range header GitHub's release redirect needs; URLSession
    /// already does, this only makes the requirement explicit.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var redirected = request
        if let range = task.originalRequest?.value(forHTTPHeaderField: "Range") {
            redirected.setValue(range, forHTTPHeaderField: "Range")
            redirected.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        }
        completionHandler(redirected)
    }

    // MARK: - Files

    private func verifyExistingImage() throws -> Bool {
        let descriptor = Darwin.open(imageURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0, Int64(information.st_size) == manifest.imageBytes else { return false }
        report(.verifying, completed: manifest.imageBytes, force: true)
        var whole = SHA256()
        try digest(descriptor: descriptor, offset: 0, bytes: manifest.imageBytes) { whole.update(bufferPointer: $0) }
        return Self.hex(whole.finalize()) == manifest.imageSHA256
    }

    /// Checks one part against its digest and feeds it to the whole-image hash.
    private func hash(_ part: FactoryDownloadManifest.Part, into whole: inout SHA256) throws -> Bool {
        var partHash = SHA256()
        var copy = whole
        try digest(descriptor: descriptor, offset: part.offset, bytes: part.bytes) {
            partHash.update(bufferPointer: $0)
            copy.update(bufferPointer: $0)
        }
        guard Self.hex(partHash.finalize()) == part.sha256 else { return false }
        whole = copy
        return true
    }

    private func digest(descriptor: Int32, offset: Int64, bytes: Int64, update: (UnsafeRawBufferPointer) -> Void) throws {
        let chunk = 4 << 20
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buffer.deallocate() }
        var done: Int64 = 0
        while done < bytes {
            try checkCancelled()
            let wanted = Int(min(Int64(chunk), bytes - done))
            let count = pread(descriptor, buffer.baseAddress, wanted, off_t(offset + done))
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw storageError("could not read the download") }
            update(UnsafeRawBufferPointer(rebasing: buffer[..<count]))
            done += Int64(count)
        }
    }

    private func fileSize() throws -> Int64 {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else { throw storageError("could not read the download") }
        return Int64(information.st_size)
    }

    private func truncate(to size: Int64) throws {
        guard ftruncate(descriptor, off_t(size)) == 0 else { throw storageError("could not repair the download") }
    }

    private func storageError(_ detail: String) -> FactoryDownloadError {
        .storage("\(detail) (\(String(cString: strerror(errno))))")
    }

    // MARK: - Retries and progress

    private func retry(after failures: inout Int, reason: String) throws {
        try checkCancelled()
        guard failures < policy.retryDelays.count else { throw FactoryDownloadError.connection(reason) }
        let delay = policy.retryDelays[failures]
        failures += 1
        fputs("[download] \(reason) Retrying in \(Int(delay)) s.\n", stderr)
        report(.retrying, completed: (try? fileSize()) ?? 0, force: true)
        try pause(delay)
    }

    private func pause(_ seconds: TimeInterval) throws {
        try checkCancelled()
        _ = wake.wait(timeout: .now() + seconds)
        try checkCancelled()
    }

    private func checkCancelled() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        if isCancelled { throw FactoryDownloadError.cancelled }
    }

    private func report(_ phase: FactoryDownloadProgress.Phase, completed: Int64, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastReport) >= policy.progressInterval else { return }
        lastReport = now
        reportProgress(FactoryDownloadProgress(phase: phase, completedBytes: completed, totalBytes: manifest.imageBytes))
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// `Content-Range: bytes first-last/total` (RFC 9110 §14.4); total may be `*`.
struct ContentRange: Equatable {
    let first: Int64
    let last: Int64
    let total: Int64?

    init?(_ value: String?) {
        guard let value, value.hasPrefix("bytes ") else { return nil }
        let fields = value.dropFirst("bytes ".count).split(separator: "/", omittingEmptySubsequences: false)
        guard fields.count == 2 else { return nil }
        let bounds = fields[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let first = Int64(bounds[0]), let last = Int64(bounds[1]),
              first >= 0, last >= first else { return nil }
        if fields[1] == "*" {
            total = nil
        } else {
            guard let total = Int64(fields[1]), total > last else { return nil }
            self.total = total
        }
        self.first = first
        self.last = last
    }
}
