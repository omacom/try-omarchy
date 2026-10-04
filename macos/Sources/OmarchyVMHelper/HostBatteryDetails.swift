import Foundation
import IOKit

/// Physical readings from AppleSmartBattery, separate from IOPS's normalized
/// 0–100 capacities. Linux consumes charge in µAh and voltage in µV.
struct HostBatteryDetails: Equatable {
    let chargeNowMicroAh: Int?
    let chargeFullMicroAh: Int?
    let chargeFullDesignMicroAh: Int?
    let voltageMicroV: Int?
    let cycleCount: Int?
    let currentMicroA: Int?

    init(properties: [String: Any] = [:]) {
        let data = properties["BatteryData"] as? [String: Any] ?? [:]
        func reading(_ candidates: [Any?], multiplier: Int = 1, minimum: Int = 0) -> Int? {
            for candidate in candidates {
                guard let number = candidate as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let value = candidate as? Int,
                      value >= minimum, value <= Int(Int32.max) / multiplier else { continue }
                return value * multiplier
            }
            return nil
        }
        chargeNowMicroAh = reading([properties["AppleRawCurrentCapacity"], data["RemainingCapacity"]], multiplier: 1000)
        chargeFullMicroAh = reading([properties["AppleRawMaxCapacity"], data["FullChargeCapacity"]], multiplier: 1000, minimum: 1)
        chargeFullDesignMicroAh = reading([properties["DesignCapacity"], data["DesignCapacity"]], multiplier: 1000, minimum: 1)
        voltageMicroV = reading([properties["Voltage"]], multiplier: 1000, minimum: 1)
        cycleCount = reading([properties["CycleCount"]])
        // Apple reports signed mA, sometimes boxed as an unsigned two's-
        // complement integer. Linux/UPower expects a magnitude; IOPS's
        // charging state remains authoritative about the direction.
        currentMicroA = [properties["Amperage"], data["Amperage"],
                         properties["InstantAmperage"], data["InstantAmperage"]].compactMap { candidate -> Int? in
            guard let number = candidate as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let signed: Int64
            if let value = number as? Int64 {
                signed = value
            } else if let value = number as? UInt64 {
                signed = Int64(bitPattern: value)
            } else {
                return nil
            }
            let maximum = Int64(Int32.max) / 1000
            guard (-maximum...maximum).contains(signed) else { return nil }
            return Int(abs(signed)) * 1000
        }.first
    }

    static func capture() -> HostBatteryDetails {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return HostBatteryDetails() }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any],
              properties["BatteryInstalled"] as? Bool != false else { return HostBatteryDetails() }
        return HostBatteryDetails(properties: properties)
    }
}
