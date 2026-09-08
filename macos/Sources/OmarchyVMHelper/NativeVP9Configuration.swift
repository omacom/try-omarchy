import Foundation

struct NativeVP9Configuration {
    let tenBit: Bool

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count == 12, bytes[0] == 1,
              bytes[1...3].allSatisfy({ $0 == 0 }), bytes[10] == 0, bytes[11] == 0,
              ((bytes[4] == 0 && bytes[6] >> 4 == 8) ||
               (bytes[4] == 2 && bytes[6] >> 4 == 10)),
              (bytes[6] >> 1) & 7 <= 1 else {
            throw HelperError.io("unsupported VP9 configuration; expected 8/10-bit 4:2:0 vpcC")
        }
        tenBit = bytes[6] >> 4 == 10
    }
}
