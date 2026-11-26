import Darwin
import Foundation
import IOKit.pwr_mgt
import Testing
@testable import OmarchyVMHelper

@Suite("Guest Stay Awake requests")
struct StayAwakeBridgeTests {
    /// Stands in for macOS's power assertions, so the tests never hold one on this Mac.
    private final class Power {
        var created = 0
        var held: Set<IOPMAssertionID> = []
        var fails = false

        func assertion() -> StayAwakeAssertion {
            StayAwakeAssertion(
                create: {
                    guard !self.fails else { return nil }
                    self.created += 1
                    let identifier = IOPMAssertionID(self.created)
                    self.held.insert(identifier)
                    return identifier
                },
                release: { self.held.remove($0) }
            )
        }
    }

    @Test("Only complete on and off lines change the state, including across read boundaries")
    func framing() {
        var requests = StayAwakeRequestBuffer()
        let chunks: [(Data, Bool?)] = [
            (Data("o".utf8), nil),
            (Data("n\n".utf8), true),
            (Data("off\non\n".utf8), true),
            (Data("on \nonoff\n".utf8), nil),
            (Data(repeating: 111, count: 10_000), nil),
            (Data("off\n".utf8), nil),
            (Data("off\n".utf8), false),
        ]
        for (chunk, expected) in chunks {
            #expect(requests.consume(chunk) == expected)
        }
    }

    @Test("The assertion is held once and released on off")
    func assertion() {
        let power = Power()
        let assertion = power.assertion()
        assertion.set(true)
        assertion.set(true)
        #expect(power.created == 1)
        #expect(power.held == [1])
        assertion.set(false)
        assertion.set(false)
        #expect(power.held.isEmpty)
    }

    @Test("An assertion macOS refused is asked for again")
    func refusedAssertion() {
        let power = Power()
        let assertion = power.assertion()
        power.fails = true
        assertion.set(true)
        #expect(power.held.isEmpty)
        power.fails = false
        assertion.set(true)
        #expect(power.held == [1])
    }

    @Test("On lasts until off, or until it is not resent")
    func expiry() {
        let start = ContinuousClock.now
        var state = StayAwakeState()
        #expect(!state.isAwake(at: start))
        state.report(true, at: start)
        #expect(state.isAwake(at: start + .seconds(29)))
        #expect(!state.isAwake(at: start + .seconds(30)))
        state.report(true, at: start + .seconds(29))
        #expect(state.isAwake(at: start + .seconds(58)))
        state.report(false, at: start + .seconds(58))
        #expect(!state.isAwake(at: start + .seconds(58)))
    }

    @Test("A silent guest loses the assertion while its socket stays open")
    func silentGuest() throws {
        let (bridge, guest) = try connectedSockets()
        defer { Darwin.close(bridge) }
        defer { Darwin.close(guest) }
        write("on\n", to: guest)
        let power = Power()
        let start = ContinuousClock.now
        var elapsed: Duration = .zero
        var turns = 0
        var heldAfterTurn: [Bool] = []
        try StayAwakeBridge.serve(descriptor: bridge, assertion: power.assertion(), now: { start + elapsed }) {
            if turns > 0 { heldAfterTurn.append(!power.held.isEmpty) }
            turns += 1
            if turns == 3 {
                elapsed = StayAwakeState.expiry
                write("not a state\n", to: guest)
            } else if turns == 2 {
                write("\n", to: guest)
            }
            return turns < 4
        }
        #expect(heldAfterTurn == [false, true, false])
        #expect(power.created == 1)
    }

    @Test("The assertion is released when QEMU closes the socket")
    func closedSocket() throws {
        let (bridge, guest) = try connectedSockets()
        defer { Darwin.close(bridge) }
        write("on\n", to: guest)
        let power = Power()
        var closed = false
        try StayAwakeBridge.serve(descriptor: bridge, assertion: power.assertion()) {
            if power.created == 0, !closed {
                write("\n", to: guest)
            } else if !closed {
                Darwin.close(guest)
                closed = true
            }
            return true
        }
        #expect(closed)
        #expect(power.created == 1)
        #expect(power.held.isEmpty)
    }

    private func connectedSockets() throws -> (Int32, Int32) {
        var descriptors: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        return (descriptors[0], descriptors[1])
    }

    private func write(_ text: String, to descriptor: Int32) {
        let data = Data(text.utf8)
        #expect(data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) } == data.count)
    }
}
