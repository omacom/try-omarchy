import Darwin
import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Guest settings requests")
struct NativeSettingsBridgeTests {
    @Test("Only complete requests open settings, including across read boundaries")
    func framing() {
        var requests = SettingsRequestBuffer()
        let chunks: [(Data, Bool)] = [
            (Data("open-set".utf8), false),
            (Data("tings\n".utf8), true),
            (Data("reset\nopen-settings /tmp/file\n".utf8), false),
            (Data(repeating: 120, count: 100_000), false),
            (Data("open-settings\n".utf8), false),
            (Data("open-settings\nopen-settings\n".utf8), true),
        ]
        for (chunk, expected) in chunks {
            let requested = requests.consume(chunk)
            #expect(requested == expected)
        }
    }

    @Test("Socket requests reach the UI callback and receive its result", arguments: [true, false])
    @MainActor
    func socketRequest(canOpen: Bool) async throws {
        var descriptors: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let peer = descriptors[1]
        defer { Darwin.close(peer) }
        var opened = 0
        let bridge = try NativeSettingsBridge(descriptor: descriptors[0]) {
            opened += 1
            return canOpen
        }
        defer { bridge.stop() }
        let request = Data("open-settings\n".utf8)
        #expect(request.withUnsafeBytes { Darwin.write(peer, $0.baseAddress, $0.count) } == request.count)
        // Yield the main actor to the dispatch source, with a bounded deadline.
        for _ in 0..<100 where opened == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(opened == 1)
        var response = [UInt8](repeating: 0, count: 64)
        #expect(fcntl(peer, F_SETFL, O_NONBLOCK) == 0)
        let count = Darwin.read(peer, &response, response.count)
        try #require(count > 0)
        #expect(String(decoding: response.prefix(count), as: UTF8.self) == (canOpen ? "opened\n" : "unavailable\n"))
    }
}
