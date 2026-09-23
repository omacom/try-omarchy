import Foundation
import IOKit

/// One USB device the Mac can hand to the guest.
///
/// QEMU matches the vendor/product pair at the selected physical bus and port.
/// Unlike a device address, this location survives re-enumeration. Moving the
/// device to another port requires choosing it again.
struct USBDeviceIdentity: Equatable, Codable {
    var vendorId: Int
    var productId: Int
    var name: String
    /// IOKit's `locationID`: the controller in the top byte, then one port
    /// number per nibble from the root down. It survives re-enumeration, unlike
    /// the bus address, and names one physical port.
    var locationId: Int? = nil

    /// The `04x:04x` form used by lsusb, so the row matches what the guest
    /// prints once the device arrives.
    var identifierText: String {
        String(format: "%04x:%04x", vendorId, productId)
    }

    var displayName: String {
        name.isEmpty ? identifierText : "\(name) · \(identifierText)"
    }

    /// The `hostbus` libusb — and so QEMU — reports for this device.
    var hostBus: Int? {
        locationId.map { ($0 >> 24) & 0xFF }
    }

    /// The `hostport` path QEMU matches, such as `1` or `2.3` behind a hub.
    var hostPort: String? {
        guard let locationId else { return nil }
        var ports: [Int] = []
        for shift in stride(from: 20, through: 0, by: -4) {
            let port = (locationId >> shift) & 0xF
            guard port != 0 else { break }
            ports.append(port)
        }
        return ports.isEmpty ? nil : ports.map(String.init).joined(separator: ".")
    }

    /// Same device model, regardless of the product string.
    func matches(_ other: USBDeviceIdentity) -> Bool {
        vendorId == other.vendorId && productId == other.productId
    }

    /// The selected model at the selected physical port, not an identical twin.
    func matchesSelection(_ other: USBDeviceIdentity) -> Bool {
        matches(other) && locationId == other.locationId
    }

    var selectionName: String {
        guard let bus = hostBus, let port = hostPort else { return displayName }
        return "\(displayName) · bus \(bus), port \(port)"
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
            let device = USBDeviceIdentity(
                vendorId: vendorId,
                productId: productId,
                name: name,
                locationId: properties["locationID"] as? Int
            )
            guard USBPassthroughPolicy.isValid(device) else { continue }
            devices.append(device)
        }
        return devices.sorted {
            if $0.name != $1.name {
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            if $0.identifierText != $1.identifierText {
                return $0.identifierText < $1.identifierText
            }
            return ($0.locationId ?? 0) < ($1.locationId ?? 0)
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

    /// Always pin the selected port, including when no twin is currently
    /// attached: QEMU keeps scanning for matching devices throughout the run.
    /// Bus 0 is exact too: the bundled QEMU carries a patch so that hostbus=0
    /// no longer means "any bus", which would otherwise cover every device
    /// behind the first controller, docks and hubs included.
    static func properties(for device: USBDeviceIdentity) -> String? {
        guard isValid(device), let location = device.locationId,
              (0...0xFFFF_FFFF).contains(location),
              let bus = device.hostBus, let port = device.hostPort else { return nil }
        let pair = String(format: "vendorid=0x%04x,productid=0x%04x", device.vendorId, device.productId)
        return "\(pair),hostbus=\(bus),hostport=\(port)"
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
        preference: USBDevicePreference,
        connected: [USBDeviceIdentity]
    ) -> Self {
        if let override = baseEnvironment[USBPassthroughPolicy.environmentKey], !override.isEmpty {
            return Self(device: nil, environment: baseEnvironment)
        }
        var environment = baseEnvironment
        environment.removeValue(forKey: USBPassthroughPolicy.environmentKey)
        guard let device = preference.activeDevice, USBPassthroughPolicy.isValid(device),
              connected.filter({ $0.matchesSelection(device) }).count == 1,
              let properties = USBPassthroughPolicy.properties(for: device) else {
            return Self(device: nil, environment: environment)
        }
        environment[USBPassthroughPolicy.environmentKey] = properties
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
    /// The saved location cannot be expressed as an exact QEMU USB filter.
    var hasUnsafeLocation = false
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
            isConnected: preference.device.map { saved in connected.contains { $0.matchesSelection(saved) } } ?? false,
            hasUnsafeLocation: preference.device.map {
                USBPassthroughPolicy.properties(for: $0) == nil
            } ?? false,
            environmentOverride: (override?.isEmpty == false) ? override : nil
        )
    }
}
