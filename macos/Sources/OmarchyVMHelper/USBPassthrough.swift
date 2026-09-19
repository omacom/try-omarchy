import Foundation
import IOKit

/// One USB device the Mac can hand to the guest.
///
/// QEMU is told to match on the vendor/product pair rather than on a bus
/// address: an iPhone re-enumerates when it is unlocked, trusted, or simply
/// unplugged and plugged back in, and a saved bus address would then point at
/// nothing — or worse, at a different device.
struct USBDeviceIdentity: Equatable, Codable {
    var vendorId: Int
    var productId: Int
    var name: String

    /// The `04x:04x` form used by lsusb, so the row matches what the guest
    /// prints once the device arrives.
    var identifierText: String {
        String(format: "%04x:%04x", vendorId, productId)
    }

    var displayName: String {
        name.isEmpty ? identifierText : "\(name) · \(identifierText)"
    }
}

/// What the guest is allowed to take over on the next launch.
struct USBDevicePreference: Equatable {
    var device: USBDeviceIdentity?
    var isEnabled: Bool

    static let disabled = Self(device: nil, isEnabled: false)

    /// The device the launcher passes through, or nil when passthrough is off.
    var activeDevice: USBDeviceIdentity? {
        guard isEnabled, let device else { return nil }
        return device
    }
}

struct USBDevicePreferenceStore {
    static let key = "usbDevicePreferences"
    static let schemaVersion = 1

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> USBDevicePreference {
        guard let data = defaults.data(forKey: Self.key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schemaVersion == Self.schemaVersion else {
            return .disabled
        }
        guard let device = payload.device, USBPassthroughPolicy.isValid(device) else {
            return .disabled
        }
        return USBDevicePreference(device: device, isEnabled: payload.isEnabled)
    }

    func save(_ preference: USBDevicePreference) {
        let payload = Payload(
            schemaVersion: Self.schemaVersion,
            device: preference.device,
            isEnabled: preference.isEnabled && preference.device != nil
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private struct Payload: Codable {
        let schemaVersion: Int
        let device: USBDeviceIdentity?
        let isEnabled: Bool
    }
}

/// The devices currently attached to this Mac, as the picker offers them.
enum HostUSBDevices {
    /// USB class 9 is a hub. Handing one to the guest would drag every device
    /// behind it along — frequently this Mac's own dock, keyboard, or display.
    static let hubDeviceClass = 9

    static func connected() -> [USBDeviceIdentity] {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var devices: [USBDeviceIdentity] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = unmanaged?.takeRetainedValue() as? [String: Any],
                  let vendorId = properties["idVendor"] as? Int,
                  let productId = properties["idProduct"] as? Int,
                  properties["bDeviceClass"] as? Int != hubDeviceClass else {
                continue
            }
            let name = (properties["USB Product Name"] as? String)
                ?? (properties["kUSBProductString"] as? String)
                ?? ""
            let device = USBDeviceIdentity(vendorId: vendorId, productId: productId, name: name)
            guard USBPassthroughPolicy.isValid(device) else { continue }
            // Two identical devices collapse into one entry: QEMU matches on
            // the pair and would claim whichever it finds first either way.
            guard !devices.contains(where: {
                $0.vendorId == vendorId && $0.productId == productId
            }) else { continue }
            devices.append(device)
        }
        return devices.sorted {
            ($0.name.localizedStandardCompare($1.name) == .orderedAscending)
                || ($0.name == $1.name && $0.identifierText < $1.identifierText)
        }
    }
}

/// Translates a chosen device into the exact `usb-host` property string the
/// launcher script validates.
enum USBPassthroughPolicy {
    static let environmentKey = "OMARCHY_QEMU_GPU_USB_HOST"

    static func isValid(_ device: USBDeviceIdentity) -> Bool {
        (0...0xFFFF).contains(device.vendorId) && (0...0xFFFF).contains(device.productId)
    }

    static func properties(for device: USBDeviceIdentity) -> String {
        String(format: "vendorid=0x%04x,productid=0x%04x", device.vendorId, device.productId)
    }
}

struct USBPassthroughLaunchConfiguration: Equatable {
    let device: USBDeviceIdentity?
    let environment: [String: String]

    /// Publishes the chosen device to the launcher script.
    ///
    /// A value already present in the environment wins and is passed through
    /// untouched, matching how the VM data folder treats its own override: a
    /// developer running `OMARCHY_QEMU_GPU_USB_HOST=… make run` gets exactly
    /// what they asked for, and the start menu says so instead of silently
    /// replacing it.
    static func make(
        baseEnvironment: [String: String],
        preference: USBDevicePreference
    ) -> Self {
        if let override = baseEnvironment[USBPassthroughPolicy.environmentKey], !override.isEmpty {
            return Self(device: nil, environment: baseEnvironment)
        }
        var environment = baseEnvironment
        environment.removeValue(forKey: USBPassthroughPolicy.environmentKey)
        guard let device = preference.activeDevice, USBPassthroughPolicy.isValid(device) else {
            return Self(device: nil, environment: environment)
        }
        environment[USBPassthroughPolicy.environmentKey] = USBPassthroughPolicy.properties(for: device)
        return Self(device: device, environment: environment)
    }
}

/// What the start menu shows for the USB row.
struct USBDeviceMenuState: Equatable {
    let device: USBDeviceIdentity?
    let isEnabled: Bool
    /// False when the saved device is not plugged in right now, so the row can
    /// say the guest will start without it rather than promising it.
    let isConnected: Bool
    let environmentOverride: String?

    static let disabled = Self(device: nil, isEnabled: false, isConnected: false, environmentOverride: nil)

    static func make(
        preference: USBDevicePreference,
        connected: [USBDeviceIdentity],
        environment: [String: String]
    ) -> Self {
        let override = environment[USBPassthroughPolicy.environmentKey]
        return Self(
            device: preference.device,
            isEnabled: preference.isEnabled && preference.device != nil,
            isConnected: preference.device.map { saved in
                connected.contains {
                    $0.vendorId == saved.vendorId && $0.productId == saved.productId
                }
            } ?? false,
            environmentOverride: (override?.isEmpty == false) ? override : nil
        )
    }
}
