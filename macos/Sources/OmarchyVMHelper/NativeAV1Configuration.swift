import Foundation

/// AV1CodecConfigurationRecord, as carried by the av1C sample entry.
/// Only Main profile 4:2:0 8/10-bit is advertised by the bridge.
struct NativeAV1Configuration {
    let tenBit: Bool

    init(_ data: Data) throws {
        guard data.count >= 4, data.count <= 1024 * 1024,
              data[0] == 0x81, data[1] >> 5 == 0,
              data[2] & 0x30 == 0, data[2] & 0x0c == 0x0c,
              data[3] & 0xe0 == 0 else {
            throw HelperError.io("unsupported AV1 configuration; expected Main 4:2:0 8/10-bit av1C")
        }
        tenBit = data[2] & 0x40 != 0
    }
}
