import Darwin
import Testing
@testable import OmarchyVMHelper

@Suite("Port forwarding socket availability")
struct PortForwardSocketTests {
    @Test("TCP preflight accepts a port with a closing or closed server connection",
          arguments: [false, true])
    func closedTCPConnectionCanRestart(finishTeardown: Bool) throws {
        let listener = try SocketFixture(type: SOCK_STREAM, reuseAddress: true)
        let port = try listener.bind()
        try #require(Darwin.listen(listener.descriptor, 1) == 0)
        let client = try SocketFixture(type: SOCK_STREAM)
        defer { client.close() }
        try client.connect(port: port)
        try listener.requireReadable()
        let acceptedDescriptor = Darwin.accept(listener.descriptor, nil, nil)
        try #require(acceptedDescriptor >= 0)
        let accepted = SocketFixture(descriptor: acceptedDescriptor)
        defer { accepted.close() }

        // Close from the server first so its endpoint, not the client, enters TIME_WAIT.
        try #require(Darwin.shutdown(accepted.descriptor, SHUT_WR) == 0)
        try client.requireEOF()
        if finishTeardown {
            try #require(Darwin.shutdown(client.descriptor, SHUT_WR) == 0)
            try accepted.requireEOF()
            accepted.close()
            client.close()
        }
        listener.close()

        let mapping = PortForwardMapping(hostPort: port, guestPort: 80, protocol: .tcp)
        try PortForwardAvailability.validate([mapping])
        try PortForwardAvailability.validate([mapping])
        let replacement = try SocketFixture(type: SOCK_STREAM, reuseAddress: true)
        #expect(try replacement.bind(port: port) == port)
        #expect(Darwin.listen(replacement.descriptor, 1) == 0)
    }

    @Test("TCP preflight rejects a live loopback listener even with address reuse",
          arguments: [false, true])
    func liveTCPListenerIsRejected(reuseAddress: Bool) throws {
        let listener = try SocketFixture(type: SOCK_STREAM, reuseAddress: reuseAddress)
        let port = try listener.bind()
        try #require(Darwin.listen(listener.descriptor, 1) == 0)
        #expect(throws: PortForwardAvailabilityError.unavailable(.tcp, port)) {
            try PortForwardAvailability.validate([
                .init(hostPort: port, guestPort: 80, protocol: .tcp),
            ])
        }
    }

    @Test("TCP preflight rejects a live wildcard listener", arguments: [false, true])
    func wildcardTCPListenerIsRejected(reuseAddress: Bool) throws {
        let listener = try SocketFixture(type: SOCK_STREAM, reuseAddress: reuseAddress)
        let port = try listener.bind(host: INADDR_ANY)
        try #require(Darwin.listen(listener.descriptor, 1) == 0)
        #expect(throws: PortForwardAvailabilityError.unavailable(.tcp, port)) {
            try PortForwardAvailability.validate([
                .init(hostPort: port, guestPort: 80, protocol: .tcp),
            ])
        }
    }

    @Test("UDP preflight rejects an occupied port and releases an available port")
    func udpOwnershipIsUnchanged() throws {
        let owner = try SocketFixture(type: SOCK_DGRAM)
        let port = try owner.bind()
        let mapping = PortForwardMapping(hostPort: port, guestPort: 53, protocol: .udp)
        #expect(throws: PortForwardAvailabilityError.unavailable(.udp, port)) {
            try PortForwardAvailability.validate([mapping])
        }
        owner.close()
        try PortForwardAvailability.validate([mapping])
        let replacement = try SocketFixture(type: SOCK_DGRAM)
        #expect(try replacement.bind(port: port) == port)
    }

    private final class SocketFixture {
        private(set) var descriptor: Int32

        init(descriptor: Int32) {
            self.descriptor = descriptor
        }

        convenience init(type: Int32, reuseAddress: Bool = false) throws {
            let descriptor = Darwin.socket(AF_INET, type, 0)
            try #require(descriptor >= 0)
            self.init(descriptor: descriptor)
            if reuseAddress {
                var enabled: Int32 = 1
                try #require(Darwin.setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR,
                                              &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0)
            }
        }

        deinit { close() }

        func close() {
            if descriptor >= 0 {
                Darwin.close(descriptor)
                descriptor = -1
            }
        }

        func bind(port: Int = 0, host: in_addr_t = INADDR_LOOPBACK) throws -> Int {
            var address = address(port: port, host: host)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            try #require(result == 0)
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let status = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(descriptor, $0, &length)
                }
            }
            try #require(status == 0)
            return Int(UInt16(bigEndian: address.sin_port))
        }

        func connect(port: Int) throws {
            var address = address(port: port, host: INADDR_LOOPBACK)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            try #require(result == 0)
        }

        func requireReadable() throws {
            var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            try #require(Darwin.poll(&readiness, 1, 2000) > 0)
            try #require(readiness.revents & Int16(POLLIN | POLLHUP) != 0)
        }

        func requireEOF() throws {
            try requireReadable()
            var byte: UInt8 = 0
            try #require(Darwin.recv(descriptor, &byte, 1, MSG_DONTWAIT) == 0)
        }

        private func address(port: Int, host: in_addr_t) -> sockaddr_in {
            var result = sockaddr_in()
            result.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            result.sin_family = sa_family_t(AF_INET)
            result.sin_port = UInt16(port).bigEndian
            result.sin_addr = in_addr(s_addr: host.bigEndian)
            return result
        }
    }
}
