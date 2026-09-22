import Foundation
import IOKit

/// One USB device the Mac can hand to the guest.
///
/// QEMU is told to match on the vendor/product pair rather than on a bus
/// address: an iPhone re-enumerates when it is unlocked, trusted, or simply
/// unplugged and plugged back in, and a saved bus address would then point at
/// nothing — or worse, at a different device. The physical port is kept as
/// well, and pins the match only when another identical device is attached.
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

    /// Same hardware regardless of the product string, which one enumeration
    /// may report and another leave empty.
    func matches(_ other: USBDeviceIdentity) -> Bool {
        vendorId == other.vendorId && productId == other.productId
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

    /// The vendor/product pair alone while the device is the only one of its
    /// kind, so it follows the device from port to port. With an identical
    /// twin attached, QEMU would take whichever it enumerates first, so the
    /// saved port is added and only that unit matches. Nil when even the port
    /// cannot single it out: passing nothing beats passing the wrong unit.
    static func properties(for device: USBDeviceIdentity, connected: [USBDeviceIdentity]) -> String? {
        let pair = String(format: "vendorid=0x%04x,productid=0x%04x", device.vendorId, device.productId)
        let twins = connected.filter { $0.matches(device) }
        guard twins.count > 1 else { return pair }
        guard let bus = device.hostBus, let port = device.hostPort else { return nil }
        // QEMU reads hostbus=0 as "any bus", and libusb numbers the first
        // controller 0, so a device there is pinned by its port path alone.
        let matched = twins.filter { $0.hostPort == port && (bus == 0 || $0.hostBus == bus) }
        guard matched.count == 1 else { return nil }
        return bus > 0 ? "\(pair),hostbus=\(bus),hostport=\(port)" : "\(pair),hostport=\(port)"
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
              let properties = USBPassthroughPolicy.properties(for: device, connected: connected) else {
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
    /// True when an identical device is attached where even the port cannot
    /// tell the two apart, so the launch leaves both with macOS.
    var isAmbiguous = false
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
            isConnected: preference.device.map { saved in connected.contains { $0.matches(saved) } } ?? false,
            isAmbiguous: preference.device.map {
                USBPassthroughPolicy.properties(for: $0, connected: connected) == nil
            } ?? false,
            environmentOverride: (override?.isEmpty == false) ? override : nil
        )
    }
}
