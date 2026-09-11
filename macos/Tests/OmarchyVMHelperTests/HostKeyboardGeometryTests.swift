import Carbon
import Testing
@testable import OmarchyVMHelper

@Suite("Host keyboard geometry")
struct HostKeyboardGeometryTests {
    @Test("classify maps only the three Carbon keyboard classes")
    func classifyKnownClasses() throws {
        #expect(try HostKeyboardGeometry.classify(Int(kKeyboardANSI)) == .ansi)
        #expect(try HostKeyboardGeometry.classify(Int(kKeyboardISO)) == .iso)
        #expect(try HostKeyboardGeometry.classify(Int(kKeyboardJIS)) == .jis)
    }

    @Test("classify fails closed on an unknown Carbon class")
    func classifyUnknownFails() {
        #expect(throws: HostKeyboardGeometry.UnknownLayoutType.self) {
            try HostKeyboardGeometry.classify(99)
        }
    }

    @Test("raw values match the guest cmdline token")
    func rawValues() {
        #expect(HostKeyboardGeometry.ansi.rawValue == "ansi")
        #expect(HostKeyboardGeometry.iso.rawValue == "iso")
        #expect(HostKeyboardGeometry.jis.rawValue == "jis")
    }
}
