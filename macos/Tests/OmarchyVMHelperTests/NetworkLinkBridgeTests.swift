import Darwin
import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Bridged network carrier recovery")
struct NetworkLinkBridgeTests {
    @Test("only complete bounded link records are accepted")
    func parsing() throws {
        #expect(try NetworkLinkSnapshot.parse(Data("1 up\n".utf8)) == .init(generation: 1, isUp: true))
        #expect(try NetworkLinkSnapshot.parse(Data("42 down\n".utf8)) == .init(generation: 42, isUp: false))
        for text in ["0 up\n", "1 up", "1  up\n", "1 up\nextra", "-1 down\n", "+1 up\n", "1 unknown\n", "18446744073709551616 up\n", String(repeating: "1", count: 65) + " up\n"] {
            #expect(throws: (any Error).self) { try NetworkLinkSnapshot.parse(Data(text.utf8)) }
        }
    }

    @Test("new up generation pulses carrier even when down was missed")
    func missedTransition() throws {
        var reducer = NetworkLinkReducer()
        var calls: [Bool] = []
        try reducer.apply(.init(generation: 1, isUp: true), setLink: { calls.append($0) }, carrierDelay: {})
        try reducer.apply(.init(generation: 3, isUp: true), setLink: { calls.append($0) }, carrierDelay: {})
        #expect(calls == [false, true, false, true])
        try reducer.apply(.init(generation: 3, isUp: true), setLink: { calls.append($0) }, carrierDelay: {})
        try reducer.apply(.init(generation: 2, isUp: false), setLink: { calls.append($0) }, carrierDelay: {})
        #expect(calls.count == 4)
    }

    @Test("failed up command keeps generation pending for retry")
    func failedUpRetry() throws {
        var reducer = NetworkLinkReducer()
        try reducer.apply(.init(generation: 2, isUp: false), setLink: { _ in }, carrierDelay: {})
        let next = NetworkLinkSnapshot(generation: 3, isUp: true)
        #expect(throws: (any Error).self) {
            try reducer.apply(next, setLink: { if $0 { throw HelperError.io("simulated QMP failure") } }, carrierDelay: {})
        }
        #expect(reducer.applied == .init(generation: 2, isUp: false))
        var calls: [Bool] = []
        try reducer.apply(next, setLink: { calls.append($0) }, carrierDelay: {})
        #expect(calls == [false, true])
        #expect(reducer.applied == next)
    }

    @Test("failed down command does not mark state applied")
    func failedDownRetry() {
        var reducer = NetworkLinkReducer()
        #expect(throws: (any Error).self) {
            try reducer.apply(.init(generation: 1, isUp: false), setLink: { _ in throw HelperError.io("simulated QMP failure") }, carrierDelay: {})
        }
        #expect(reducer.applied == nil)
    }

    @Test("QMP recovery retries with a new connection and the explicit NIC id")
    func qmpRecoveryRetry() throws {
        var reducer = NetworkLinkReducer()
        let snapshot = NetworkLinkSnapshot(generation: 3, isUp: true)
        let failed = try LinkQMPServer(expectedUp: [false, true], failLast: true)
        #expect(throws: (any Error).self) {
            try reducer.apply(snapshot, connectionFactory: {
                try QMPConnection(connectedDescriptor: failed.client, identifierPrefix: "link-test")
            }, isTargetAlive: { true }, carrierDelay: {})
        }
        #expect(reducer.applied == nil)
        failed.finish()
        let recovered = try LinkQMPServer(expectedUp: [false, true])
        try reducer.apply(snapshot, connectionFactory: {
            try QMPConnection(connectedDescriptor: recovered.client, identifierPrefix: "link-test")
        }, isTargetAlive: { true }, carrierDelay: {})
        recovered.finish()
        #expect(reducer.applied == snapshot)
        try reducer.apply(snapshot, connectionFactory: {
            throw HelperError.io("an applied generation must not reconnect")
        }, isTargetAlive: { true }, carrierDelay: {})
    }

    @Test("failed QMP capability negotiation leaves recovery pending")
    func negotiationRetry() throws {
        var reducer = NetworkLinkReducer()
        let snapshot = NetworkLinkSnapshot(generation: 1, isUp: false)
        let rejected = try LinkQMPServer(expectedUp: [], rejectNegotiation: true)
        #expect(throws: (any Error).self) {
            try reducer.apply(snapshot, connectionFactory: {
                try QMPConnection(connectedDescriptor: rejected.client, identifierPrefix: "link-test")
            }, isTargetAlive: { true }, carrierDelay: {})
        }
        rejected.finish()
        #expect(reducer.applied == nil)
        let retried = try LinkQMPServer(expectedUp: [false])
        try reducer.apply(snapshot, connectionFactory: {
            try QMPConnection(connectedDescriptor: retried.client, identifierPrefix: "link-test")
        }, isTargetAlive: { true }, carrierDelay: {})
        retried.finish()
        #expect(reducer.applied == snapshot)
    }

    @Test("QMP pathname connection binds to the expected peer process")
    func peerPIDValidation() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/link-peer-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("qmp").path
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(listener >= 0)
        defer { close(listener) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, listen(listener, 2) == 0 else {
            throw HelperError.io("Cannot bind QMP peer test listener: \(errno)")
        }
        let connectionPath = URL(fileURLWithPath: path).standardizedFileURL.path
        // Wrong peer is rejected before greeting or capability negotiation.
        do {
            let unexpected = try QMPConnection(socketPath: connectionPath, identifierPrefix: "wrong-peer", timeoutMilliseconds: 100, expectedPeerPID: getpid() + 1)
            unexpected.close()
            Issue.record("QMP connection accepted a mismatched peer")
        } catch {
            #expect(String(describing: error).contains("peer does not match"))
        }
        var readiness = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&readiness, 1, 1000) > 0 else { throw HelperError.io("Rejected QMP peer never connected") }
        let rejected = accept(listener, nil, nil)
        #expect(rejected >= 0)
        if rejected >= 0 { close(rejected) }
        let finished = DispatchSemaphore(value: 0)
        let ready = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            ready.signal()
            defer { finished.signal() }
            var readiness = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&readiness, 1, 2000) > 0 else {
                Issue.record("Matching QMP peer never connected")
                return
            }
            let peer = accept(listener, nil, nil)
            guard peer >= 0 else { return }
            defer { close(peer) }
            do {
                try LinkQMPServer.suppressSIGPIPE(descriptor: peer)
                try LinkQMPServer.negotiate(descriptor: peer)
            } catch {
                Issue.record("Peer validation mock failed: \(error)")
            }
        }
        defer { #expect(finished.wait(timeout: .now() + 3) == .success) }
        guard ready.wait(timeout: .now() + 3) == .success else {
            throw HelperError.io("QMP peer test server did not start")
        }
        let accepted = try QMPConnection(socketPath: connectionPath, identifierPrefix: "matching-peer", expectedPeerPID: getpid())
        accepted.close()
    }

    @Test("secure reader rejects writable metadata, links, and wrong owner")
    func secureReader() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent("network-link-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("link-state").path
        try Data("7 up\n".utf8).write(to: URL(fileURLWithPath: path))
        #expect(chmod(path, 0o600) == 0)
        #expect(try NetworkLinkStateReader.read(path: path, expectedOwner: getuid()).generation == 7)
        #expect(throws: (any Error).self) { try NetworkLinkStateReader.read(path: path, expectedOwner: getuid() == 0 ? 1 : 0) }
        #expect(chmod(path, 0o622) == 0)
        #expect(throws: (any Error).self) { try NetworkLinkStateReader.read(path: path, expectedOwner: getuid()) }
        #expect(chmod(path, 0o600) == 0)
        #expect(chmod(directory.path, 0o722) == 0)
        #expect(throws: (any Error).self) { try NetworkLinkStateReader.read(path: path, expectedOwner: getuid()) }
        #expect(chmod(directory.path, 0o700) == 0)
        #expect(chmod(directory.path, 0o100) == 0)
        #expect(try NetworkLinkStateReader.read(path: path, expectedOwner: getuid()).generation == 7)
        #expect(chmod(directory.path, 0o700) == 0)
        let alias = directory.appendingPathComponent("alias").path
        #expect(symlink(path, alias) == 0)
        #expect(throws: (any Error).self) { try NetworkLinkStateReader.read(path: alias, expectedOwner: getuid()) }
        let hardlink = directory.appendingPathComponent("hardlink").path
        #expect(link(path, hardlink) == 0)
        #expect(throws: (any Error).self) { try NetworkLinkStateReader.read(path: path, expectedOwner: getuid()) }
    }
}

private final class LinkQMPServer: @unchecked Sendable {
    let client: Int32
    private let finished = DispatchSemaphore(value: 0)

    init(expectedUp: [Bool], failLast: Bool = false, rejectNegotiation: Bool = false) throws {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw HelperError.io("Cannot create network recovery mock")
        }
        client = descriptors[0]
        let server = descriptors[1]
        let finished = finished
        Thread.detachNewThread {
            defer { close(server); finished.signal() }
            do {
                try Self.suppressSIGPIPE(descriptor: server)
                try Self.negotiate(descriptor: server, reject: rejectNegotiation)
                if rejectNegotiation { return }
                for (index, isUp) in expectedUp.enumerated() {
                    let request = try Self.readRequest(descriptor: server)
                    let arguments = request["arguments"] as? [String: Any]
                    guard request["execute"] as? String == "set_link",
                          arguments?["name"] as? String == "omarchy-nic",
                          arguments?["up"] as? Bool == isUp,
                          let identifier = request["id"] as? String else {
                        throw HelperError.io("Unexpected network recovery QMP command")
                    }
                    // Exercise asynchronous events interleaved with replies.
                    try QMPConnection.writeJSON(["event": "NIC_RX_FILTER_CHANGED"], to: server)
                    if failLast && index == expectedUp.count - 1 {
                        try QMPConnection.writeJSON(["id": identifier, "error": ["class": "GenericError", "desc": "simulated recovery failure"]], to: server)
                    } else {
                        try QMPConnection.writeJSON(["id": identifier, "return": [:]], to: server)
                    }
                }
            } catch {
                Issue.record("Network recovery mock failed: \(error)")
            }
        }
    }

    func finish() {
        #expect(finished.wait(timeout: .now() + 3) == .success)
    }

    static func suppressSIGPIPE(descriptor: Int32) throws {
        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw HelperError.io("Cannot configure mock QMP socket")
        }
    }

    static func negotiate(descriptor: Int32, reject: Bool = false) throws {
        try QMPConnection.writeJSON(["QMP": ["capabilities": []]], to: descriptor)
        let request = try readRequest(descriptor: descriptor)
        guard request["execute"] as? String == "qmp_capabilities", let identifier = request["id"] as? String else {
            throw HelperError.io("Expected QMP capabilities")
        }
        if reject {
            try QMPConnection.writeJSON(["id": identifier, "error": ["class": "GenericError", "desc": "simulated negotiation failure"]], to: descriptor)
        } else {
            try QMPConnection.writeJSON(["id": identifier, "return": [:]], to: descriptor)
        }
    }

    private static func readRequest(descriptor: Int32) throws -> [String: Any] {
        var data = Data()
        while data.count < 4096 {
            var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&readiness, 1, 2000) > 0 else { throw HelperError.io("Mock QMP request timed out") }
            var byte: UInt8 = 0
            guard read(descriptor, &byte, 1) == 1 else { throw HelperError.io("Mock QMP peer closed") }
            if byte == 10 {
                guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw HelperError.io("Invalid mock QMP request")
                }
                return request
            }
            if byte != 13 { data.append(byte) }
        }
        throw HelperError.io("Mock QMP request too large")
    }
}
