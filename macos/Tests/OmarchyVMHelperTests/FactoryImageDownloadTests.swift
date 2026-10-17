import CryptoKit
import Darwin
import Foundation
import Testing
@testable import OmarchyVMHelper

/// A scripted HTTP server behind URLProtocol. Each test gets its own host, so
/// suites running in parallel never share a script.
private final class StubFactoryServer: @unchecked Sendable {
    enum Behavior {
        case serve
        /// Sends this many body bytes, then loses the connection.
        case drop(after: Int)
        /// Answers a ranged request with the whole file.
        case ignoreRange
        case status(Int)
        /// Serves the range with one byte changed.
        case corrupt
        case wrongRange
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: StubFactoryServer] = [:]

    let host = "factory-\(UUID().uuidString.lowercased()).test"
    let files: [String: Data]
    private var script: [Behavior]
    private(set) var ranges: [String] = []

    init(files: [String: Data], script: [Behavior] = []) {
        self.files = files
        self.script = script
        Self.lock.lock()
        Self.servers[host] = self
        Self.lock.unlock()
    }

    static func server(for host: String?) -> StubFactoryServer? {
        lock.lock()
        defer { lock.unlock() }
        return host.flatMap { servers[$0] }
    }

    func next(range: String?) -> Behavior {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        ranges.append(range ?? "")
        return script.isEmpty ? .serve : script.removeFirst()
    }

    var requestedRanges: [String] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return ranges
    }
}

private final class StubFactoryProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let server = StubFactoryServer.server(for: url.host),
              let file = server.files[url.path] else {
            respond(status: 404, headers: [:], body: Data())
            return
        }
        let range = request.value(forHTTPHeaderField: "Range")
        var first = 0
        var last = file.count - 1
        if let range, range.hasPrefix("bytes=") {
            let bounds = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            first = Int(bounds[0]) ?? 0
            last = bounds.count > 1 ? Int(bounds[1]) ?? last : last
        }
        let total = file.count
        switch server.next(range: range) {
        case .serve:
            respondRange(file, first: first, last: last, total: total)
        case .drop(let count):
            let response = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Range": "bytes \(first)-\(last)/\(total)", "Content-Length": "\(last - first + 1)",
            ])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: file.subdata(in: first..<min(first + count, last + 1)))
            // A real connection delivers what arrived before it fails.
            Thread.sleep(forTimeInterval: 0.05)
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case .ignoreRange:
            respond(status: 200, headers: ["Content-Length": "\(total)"], body: file)
        case .status(let code):
            respond(status: code, headers: [:], body: Data("error".utf8))
        case .corrupt:
            var body = file.subdata(in: first..<(last + 1))
            body[body.startIndex] ^= 0xff
            respond(status: 206, headers: ["Content-Range": "bytes \(first)-\(last)/\(total)"], body: body)
        case .wrongRange:
            respondRange(file, first: 0, last: last, total: total)
        }
    }

    private func respondRange(_ file: Data, first: Int, last: Int, total: Int) {
        respond(status: 206, headers: [
            "Content-Range": "bytes \(first)-\(last)/\(total)", "Content-Length": "\(last - first + 1)",
        ], body: file.subdata(in: first..<(last + 1)))
    }

    private func respond(status: Int, headers: [String: String], body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Several chunks, as a real connection delivers them.
        var offset = 0
        while offset < body.count {
            let end = min(offset + 7_000, body.count)
            client?.urlProtocol(self, didLoad: body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

private func sha256(_ data: Data) -> String {
    FactoryImageDownloader.hex(SHA256.hash(data: data))
}

private struct Fixture {
    let directory: URL
    let image: Data
    let parts: [Data]
    let manifest: FactoryDownloadManifest
    let server: StubFactoryServer

    init(partSizes: [Int] = [120_000, 120_000, 60_000], script: [StubFactoryServer.Behavior] = []) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("factory-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var generator = SystemRandomNumberGenerator()
        image = Data((0..<partSizes.reduce(0, +)).map { _ in UInt8.random(in: 0...255, using: &generator) })
        var parts: [Data] = []
        var offset = 0
        for size in partSizes {
            parts.append(image.subdata(in: offset..<(offset + size)))
            offset += size
        }
        self.parts = parts
        var files: [String: Data] = [:]
        for (index, part) in parts.enumerated() { files["/part\(index + 1)"] = part }
        let server = StubFactoryServer(files: files, script: script)
        self.server = server
        let entries = parts.enumerated().map { index, part in
            ["url": "https://\(server.host)/part\(index + 1)", "bytes": part.count, "sha256": sha256(part)] as [String: Any]
        }
        let json: [String: Any] = [
            "format": 1, "kind": "try-omarchy-factory-download", "identity": String(repeating: "a", count: 64),
            "image": ["bytes": parts.reduce(0) { $0 + $1.count }, "sha256": sha256(parts.reduce(Data(), +))], "parts": entries,
        ]
        manifest = try #require(FactoryDownloadManifest.decode(JSONSerialization.data(withJSONObject: json)))
    }

    func downloader(
        retryDelays: [TimeInterval] = [0, 0, 0],
        freeBytes: @escaping (URL) -> Int64? = { _ in Int64.max / 4 },
        spaceCheckBytes: Int64 = 128 << 20
    ) -> FactoryImageDownloader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubFactoryProtocol.self]
        var policy = FactoryImageDownloader.Policy()
        policy.retryDelays = retryDelays
        policy.lockPollInterval = 0.02
        policy.spaceCheckBytes = spaceCheckBytes
        return FactoryImageDownloader(manifest: manifest, directory: directory, reserveBytes: 0,
                                      policy: policy, configuration: configuration, freeBytes: freeBytes)
    }

    var imageURL: URL { FactoryImageStore.imageURL(in: directory, identity: manifest.identity) }
    var partialURL: URL { FactoryImageStore.partialURL(in: directory, identity: manifest.identity) }

    func partialSize() -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: partialURL.path))?[.size] as? NSNumber)?.intValue ?? -1
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

@Suite("Factory image download", .serialized)
struct FactoryImageDownloadTests {
    @Test("downloads every part into one verified image")
    func downloadsAllParts() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var phases: [FactoryDownloadProgress.Phase] = []
        let url = try fixture.downloader().run { phases.append($0.phase) }
        #expect(url == fixture.imageURL)
        #expect(try Data(contentsOf: url) == fixture.image)
        #expect(!FileManager.default.fileExists(atPath: fixture.partialURL.path))
        #expect(fixture.server.requestedRanges == ["bytes=0-119999", "bytes=0-119999", "bytes=0-59999"])
        #expect(phases.contains(.downloading) && phases.contains(.verifying))
        let mode = (try FileManager.default.attributesOfItem(atPath: url.path))[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }

    @Test("a lost connection resumes from the last byte written")
    func resumesAfterDrop() throws {
        let fixture = try Fixture(script: [.serve, .drop(after: 50_000)])
        defer { fixture.cleanUp() }
        var phases: [FactoryDownloadProgress.Phase] = []
        _ = try fixture.downloader().run { phases.append($0.phase) }
        #expect(try Data(contentsOf: fixture.imageURL) == fixture.image)
        #expect(fixture.server.requestedRanges == ["bytes=0-119999", "bytes=0-119999", "bytes=50000-119999", "bytes=0-59999"])
        #expect(phases.contains(.retrying))
    }

    @Test("a download stopped by the network continues on the next launch")
    func resumesAcrossRuns() throws {
        let fixture = try Fixture(script: [.serve, .drop(after: 30_000), .status(503)])
        defer { fixture.cleanUp() }
        #expect(throws: FactoryDownloadError.self) {
            _ = try fixture.downloader(retryDelays: [0]).run { _ in }
        }
        #expect(fixture.partialSize() == 150_000)
        _ = try fixture.downloader().run { _ in }
        #expect(try Data(contentsOf: fixture.imageURL) == fixture.image)
        #expect(fixture.server.requestedRanges.suffix(2) == ["bytes=30000-119999", "bytes=0-59999"])
    }

    @Test("a server that ignores the range restarts the part instead of appending it")
    func ignoredRange() throws {
        let fixture = try Fixture(script: [.drop(after: 40_000), .ignoreRange])
        defer { fixture.cleanUp() }
        _ = try fixture.downloader().run { _ in }
        #expect(try Data(contentsOf: fixture.imageURL) == fixture.image)
    }

    @Test("a mismatched Content-Range is never appended")
    func wrongRange() throws {
        let fixture = try Fixture(script: [.drop(after: 40_000), .wrongRange])
        defer { fixture.cleanUp() }
        _ = try fixture.downloader().run { _ in }
        #expect(try Data(contentsOf: fixture.imageURL) == fixture.image)
        #expect(fixture.server.requestedRanges.prefix(3) == ["bytes=0-119999", "bytes=40000-119999", "bytes=0-119999"])
    }

    @Test("a damaged part is fetched again; one that stays damaged fails without losing earlier parts")
    func damagedParts() throws {
        let repaired = try Fixture(script: [.serve, .corrupt])
        defer { repaired.cleanUp() }
        _ = try repaired.downloader().run { _ in }
        #expect(try Data(contentsOf: repaired.imageURL) == repaired.image)

        let broken = try Fixture(script: [.serve, .corrupt, .corrupt, .corrupt])
        defer { broken.cleanUp() }
        #expect(throws: FactoryDownloadError.damaged) { _ = try broken.downloader().run { _ in } }
        #expect(broken.partialSize() == 120_000)
        #expect(!FileManager.default.fileExists(atPath: broken.imageURL.path))
    }

    @Test("bytes damaged on disk while the app was closed are found and replaced")
    func damagedOnDisk() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var stored = fixture.image.prefix(250_000)
        stored[stored.startIndex + 5] ^= 0x01
        try Data(stored).write(to: fixture.partialURL)
        _ = try fixture.downloader().run { _ in }
        #expect(try Data(contentsOf: fixture.imageURL) == fixture.image)
        // Part 1 failed its check, part 2 was then appended from scratch.
        #expect(fixture.server.requestedRanges == ["bytes=0-119999", "bytes=0-119999", "bytes=0-59999"])
    }

    @Test("an over-long leftover file starts over")
    func overlongPartial() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try Data(repeating: 7, count: fixture.image.count + 10).write(to: fixture.partialURL)
        _ = try fixture.downloader().run { _ in }
        #expect(try Data(contentsOf: fixture.imageURL) == fixture.image)
    }

    @Test("a missing asset fails at once; a busy server is retried")
    func httpStatuses() throws {
        let missing = try Fixture(script: [.status(404)])
        defer { missing.cleanUp() }
        #expect(throws: FactoryDownloadError.unavailable(statusCode: 404)) { _ = try missing.downloader().run { _ in } }
        #expect(missing.server.requestedRanges.count == 1)

        let busy = try Fixture(script: [.status(503), .status(429), .serve])
        defer { busy.cleanUp() }
        _ = try busy.downloader().run { _ in }
        #expect(try Data(contentsOf: busy.imageURL) == busy.image)
    }

    @Test("repeated failures without progress end with a connection error")
    func givesUp() throws {
        let fixture = try Fixture(script: Array(repeating: .status(500), count: 10))
        defer { fixture.cleanUp() }
        #expect {
            _ = try fixture.downloader(retryDelays: [0, 0]).run { _ in }
        } throws: { error in
            guard case .connection = error as? FactoryDownloadError else { return false }
            return true
        }
        #expect(fixture.server.requestedRanges.count == 3)
    }

    @Test("a verified image is reused; a damaged one is replaced")
    func existingImage() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.image.write(to: fixture.imageURL)
        _ = try fixture.downloader().run { _ in }
        #expect(fixture.server.requestedRanges.isEmpty)

        var damaged = fixture.image
        damaged[damaged.startIndex] ^= 0x01
        try damaged.write(to: fixture.imageURL)
        _ = try fixture.downloader().run { _ in }
        #expect(try Data(contentsOf: fixture.imageURL) == fixture.image)
        #expect(fixture.server.requestedRanges.count == 3)
    }

    @Test("there must be room for the rest of the download and the decompressed disk")
    func freeSpace() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        #expect(throws: FactoryDownloadError.insufficientSpace(needed: 300_000, available: 1_000)) {
            _ = try fixture.downloader(freeBytes: { _ in 1_000 }).run { _ in }
        }
        #expect(fixture.server.requestedRanges.isEmpty)
    }

    @Test("the download stops before something else fills the disk, and keeps what it has")
    func runsOutOfSpace() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        // Enough to start; then another app takes the space.
        let calls = Counter()
        let downloader = fixture.downloader(freeBytes: { _ in
            calls.increment() == 1 ? 10 << 30 : (1 << 30) + 100_000
        }, spaceCheckBytes: 50_000)
        #expect {
            _ = try downloader.run { _ in }
        } throws: { error in
            guard case .diskFull(let downloaded) = error as? FactoryDownloadError else { return false }
            return downloaded > 0 && downloaded < 300_000
        }
        #expect(fixture.partialSize() > 0)
        _ = try fixture.downloader().run { _ in }
        #expect(try Data(contentsOf: fixture.imageURL) == fixture.image)
    }

    @Test("a second app instance waits for the first instance's download")
    func waitsForLock() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let holder = open(fixture.directory.path, O_RDONLY | O_DIRECTORY)
        #expect(flock(holder, LOCK_EX) == 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            try? fixture.image.write(to: fixture.imageURL)
            flock(holder, LOCK_UN)
            close(holder)
        }
        var phases: [FactoryDownloadProgress.Phase] = []
        _ = try fixture.downloader().run { phases.append($0.phase) }
        #expect(phases.first == .waiting)
        #expect(fixture.server.requestedRanges.isEmpty)
    }

    @Test("cancelling keeps what was downloaded")
    func cancels() throws {
        let fixture = try Fixture(script: [.serve, .drop(after: 10_000)])
        defer { fixture.cleanUp() }
        let downloader = fixture.downloader(retryDelays: [30])
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { downloader.cancel() }
        #expect(throws: FactoryDownloadError.cancelled) { _ = try downloader.run { _ in } }
        #expect(fixture.partialSize() == 130_000)
    }
}

@Suite("Factory download manifest")
struct FactoryDownloadManifestTests {
    private func json(parts: [[String: Any]], bytes: Int = 10) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "format": 1, "kind": "try-omarchy-factory-download", "identity": String(repeating: "b", count: 64),
            "image": ["bytes": bytes, "sha256": String(repeating: "c", count: 64)], "parts": parts,
        ] as [String: Any])
    }

    private func part(_ url: String, _ bytes: Int = 5) -> [String: Any] {
        ["url": url, "bytes": bytes, "sha256": String(repeating: "d", count: 64)]
    }

    @Test("parts become consecutive ranges of the image")
    func offsets() throws {
        let manifest = try #require(FactoryDownloadManifest.decode(json(parts: [
            part("https://github.com/omacom/try-omarchy/releases/download/v1.0.0/a.001"),
            part("https://github.com/omacom/try-omarchy/releases/download/v1.0.0/a.002"),
        ])))
        #expect(manifest.parts.map(\.offset) == [0, 5])
        #expect(manifest.parts.map(\.end) == [5, 10])
    }

    @Test("rejects sizes that do not add up, plain HTTP to other hosts, and bad digests")
    func rejects() {
        #expect(FactoryDownloadManifest.decode(json(parts: [part("https://example.com/a")])) == nil)
        #expect(FactoryDownloadManifest.decode(json(parts: [part("http://example.com/a"), part("https://example.com/b")])) == nil)
        #expect(FactoryDownloadManifest.decode(json(parts: [part("file:///etc/a"), part("https://example.com/b")])) == nil)
        #expect(FactoryDownloadManifest.decode(json(parts: [])) == nil)
        var bad = part("https://example.com/a")
        bad["sha256"] = "XYZ"
        #expect(FactoryDownloadManifest.decode(json(parts: [bad, part("https://example.com/b")])) == nil)
        #expect(FactoryDownloadManifest.decode(json(parts: [part("http://127.0.0.1:8000/a"), part("https://example.com/b")])) != nil)
    }

    @Test("Content-Range parsing")
    func contentRange() {
        #expect(ContentRange("bytes 5-9/10") == ContentRange("bytes 5-9/10"))
        #expect(ContentRange("bytes 5-9/10")?.first == 5)
        #expect(ContentRange("bytes 5-9/*")?.total == nil)
        #expect(ContentRange("bytes 9-5/10") == nil)
        #expect(ContentRange("bytes 5-9/9") == nil)
        #expect(ContentRange("items 5-9/10") == nil)
        #expect(ContentRange(nil) == nil)
    }

    @Test("progress titles")
    func titles() {
        let total: Int64 = 3_036_546_680
        #expect(FactoryDownloadProgress(phase: .downloading, completedBytes: total / 2, totalBytes: total).title
            == "Downloading Omarchy… 50% of 3.0 GB")
        #expect(FactoryDownloadProgress(phase: .retrying, completedBytes: 0, totalBytes: total).title
            == "Reconnecting… 0% downloaded")
    }
}

@Suite("Factory image preparation")
struct FactoryImagePreparationTests {
    private let identity = String(repeating: "e", count: 64)

    private func manifest() throws -> FactoryDownloadManifest {
        try #require(FactoryDownloadManifest.decode(JSONSerialization.data(withJSONObject: [
            "format": 1, "kind": "try-omarchy-factory-download", "identity": identity,
            "image": ["bytes": 4, "sha256": String(repeating: "f", count: 64)],
            "parts": [["url": "https://example.com/a", "bytes": 4, "sha256": String(repeating: "f", count: 64)]],
        ] as [String: Any])))
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("factory-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shell"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shell-factory"), withIntermediateDirectories: true)
        return root
    }

    @Test("only a new VM without a decompressed factory downloads")
    func plan() throws {
        let manifest = try manifest()
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let factory = root.appendingPathComponent("shell-factory", isDirectory: true)

        #expect(FactoryImagePreparation.plan(manifest: manifest, bundlesImage: true, stateRoot: root, sharedFactory: nil) == .ready(image: nil))
        #expect(FactoryImagePreparation.plan(manifest: nil, bundlesImage: false, stateRoot: root, sharedFactory: nil) == .ready(image: nil))
        #expect(FactoryImagePreparation.plan(manifest: manifest, bundlesImage: false, stateRoot: root, sharedFactory: nil) == .download(directory: factory))

        let image = FactoryImageStore.imageURL(in: factory, identity: identity)
        try Data("zstd".utf8).write(to: image)
        // Still a download: the downloader verifies the file before it is used.
        #expect(FactoryImagePreparation.plan(manifest: manifest, bundlesImage: false, stateRoot: root, sharedFactory: nil) == .download(directory: factory))

        try Data().write(to: root.appendingPathComponent("shell/disk.img"))
        #expect(FactoryImagePreparation.plan(manifest: manifest, bundlesImage: false, stateRoot: root, sharedFactory: nil) == .ready(image: image))

        try FileManager.default.removeItem(at: root.appendingPathComponent("shell/disk.img"))
        try Data().write(to: FactoryImageStore.factoryDiskURL(in: factory, identity: identity))
        #expect(FactoryImagePreparation.plan(manifest: manifest, bundlesImage: false, stateRoot: root, sharedFactory: nil) == .ready(image: image))
    }

    @Test("a disposable VM downloads into the storage folder it clones from")
    func sharedFactory() throws {
        let manifest = try manifest()
        let main = try root()
        let session = try root()
        defer {
            try? FileManager.default.removeItem(at: main)
            try? FileManager.default.removeItem(at: session)
        }
        let shared = main.appendingPathComponent("shell-factory", isDirectory: true)
        #expect(FactoryImagePreparation.plan(manifest: manifest, bundlesImage: false, stateRoot: session, sharedFactory: shared) == .download(directory: shared))
        try Data().write(to: FactoryImageStore.factoryDiskURL(in: shared, identity: identity))
        #expect(FactoryImagePreparation.plan(manifest: manifest, bundlesImage: false, stateRoot: session, sharedFactory: shared) == .ready(image: nil))
    }

    @Test("the download folder is marked as a workspace, and a missing chosen folder is not recreated")
    func prepareDirectory() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("factory-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: container) }
        let directory = container.appendingPathComponent("v1/shell-factory", isDirectory: true)
        #expect(throws: FactoryDownloadError.self) {
            try FactoryImageStore.prepareDirectory(directory, mayCreateRoot: false)
        }
        #expect(!FileManager.default.fileExists(atPath: container.path))
        try FactoryImageStore.prepareDirectory(directory, mayCreateRoot: true)
        #expect(StorageLocationPolicy.hasValidRootMarker(in: directory.deletingLastPathComponent()))
        let mode = (try FileManager.default.attributesOfItem(atPath: directory.path))[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o700)
        try FactoryImageStore.prepareDirectory(directory, mayCreateRoot: false)
    }

    @Test("downloads are removed once their factory is decompressed, and other factories' at once")
    func cleanup() throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let factory = root.appendingPathComponent("shell-factory", isDirectory: true)
        let old = String(repeating: "0", count: 64)
        let names = ["\(old).img.zst", "\(old).img.zst.download", "\(identity).img.zst", "\(identity).img.zst.download", "\(old).img", "notes.img.zst"]
        for name in names { try Data().write(to: factory.appendingPathComponent(name)) }
        FactoryImageStore.removeObsoleteDownloads(in: factory, identity: identity)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: factory.path))
            == ["\(identity).img.zst", "\(identity).img.zst.download", "\(old).img", "notes.img.zst"])
        try Data().write(to: FactoryImageStore.factoryDiskURL(in: factory, identity: identity))
        FactoryImageStore.removeObsoleteDownloads(in: factory, identity: identity)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: factory.path))
            == ["\(identity).img", "\(old).img", "notes.img.zst"])
    }

    @Test("the space floor includes the download")
    func spaceFloor() {
        let requirement = StorageSpaceRequirement(sourceBytes: 10, workingBytes: 20, downloadBytes: 3)
        #expect(requirement.floorBytes == 13 + StorageSpaceRequirement.headroomBytes)
    }
}
