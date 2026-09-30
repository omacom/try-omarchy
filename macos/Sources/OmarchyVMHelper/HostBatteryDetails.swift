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
