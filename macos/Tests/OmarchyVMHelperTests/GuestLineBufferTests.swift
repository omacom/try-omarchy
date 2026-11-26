import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Guest line framing")
struct GuestLineBufferTests {
    @Test("Lines complete across read boundaries, and a line over the limit is dropped whole")
    func framing() {
        var buffer = GuestLineBuffer(maximumLineBytes: 4)
        let chunks: [(String, [String])] = [
            ("ab", []),
            ("c\n\nd", ["abc", ""]),
            ("\n1234\n", ["d", "1234"]),
            ("12345\nok\n", ["ok"]),
            ("123456", []),
            ("78\nok\n", ["ok"]),
        ]
        for (chunk, expected) in chunks {
            #expect(buffer.consume(Data(chunk.utf8)) == expected.map { Data($0.utf8) })
        }
    }
}
