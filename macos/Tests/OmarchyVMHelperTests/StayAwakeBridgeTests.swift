import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Guest Stay Awake requests")
struct StayAwakeBridgeTests {
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
        let assertion = StayAwakeAssertion()
        assertion.set(true)
        assertion.set(true)
        #expect(assertion.isHeld)
        assertion.set(false)
        #expect(!assertion.isHeld)
    }
}
