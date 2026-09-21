import Carbon

enum HostKeyboardGeometry: String {
    case ansi
    case iso
    case jis

    struct UnknownLayoutType: Error, Equatable {
        let rawValue: Int
    }

    static func classify(_ layoutType: Int) throws -> HostKeyboardGeometry {
        switch layoutType {
        case Int(kKeyboardANSI):
            return .ansi
        case Int(kKeyboardISO):
            return .iso
        case Int(kKeyboardJIS):
            return .jis
        default:
            throw UnknownLayoutType(rawValue: layoutType)
        }
    }

    static func detect() throws -> HostKeyboardGeometry {
        try classify(Int(KBGetLayoutType(Int16(LMGetKbdType()))))
    }
}
