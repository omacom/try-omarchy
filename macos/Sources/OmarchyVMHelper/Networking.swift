import Foundation
import Darwin
import SystemConfiguration

enum VMNetworkMode: String, Codable, CaseIterable {
    case nat, bridged
}

struct VMNetworkPreferences: Codable, Equatable {
    var mode: VMNetworkMode = .nat
    var interface: String = ""
    var wifiCompatibility: Bool = false
    var bridgedSSH: Bool = false
}

struct VMNetworkPreferenceStore {
    static let key = "networkPreferences"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> VMNetworkPreferences {
        guard let data = defaults.data(forKey: Self.key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == 1 else { return VMNetworkPreferences() }
        return payload.preferences
    }

    func save(_ preferences: VMNetworkPreferences) throws {
        if preferences.mode == .bridged && !VMNetworkPolicy.validInterface(preferences.interface) {
            throw HelperError.io("Choose an available interface for bridged networking.")
        }
        defaults.set(try JSONEncoder().encode(Payload(version: 1, preferences: preferences)), forKey: Self.key)
    }

    private struct Payload: Codable {
        let version: Int
        let preferences: VMNetworkPreferences
    }
}

enum VMNetworkPolicy {
    static let modeKey = "OMARCHY_NETWORK_MODE"
    static let interfaceKey = "OMARCHY_NETWORK_INTERFACE"
    static let compatibilityKey = "OMARCHY_NETWORK_WIFI_COMPATIBILITY"
    static let sshKey = "OMARCHY_NETWORK_BRIDGED_SSH"
    static let ownerKey = "OMARCHY_NETWORK_OWNER_PID"
    static let keys = [modeKey, interfaceKey, compatibilityKey, sshKey, ownerKey]

    static var supportsWiFiCompatibility: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("net.link.bridge.use_dhcp_xid", &value, &size, nil, 0) == 0
            && size == MemoryLayout<Int32>.size
    }

    static func requiresWiFiCompatibility(isWiFi: Bool, supported: Bool) -> Bool {
        isWiFi && supported
    }

    static func validInterface(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z][A-Za-z0-9]{0,31}\\z", options: .regularExpression) != nil
    }

    static func environment(base: [String: String], preferences: VMNetworkPreferences) -> [String: String] {
        var result = base
        for key in keys { result.removeValue(forKey: key) }
        result[modeKey] = preferences.mode.rawValue
        result[ownerKey] = String(ProcessInfo.processInfo.processIdentifier)
        if preferences.mode == .bridged {
            result[interfaceKey] = preferences.interface
            result[compatibilityKey] = preferences.wifiCompatibility ? "1" : "0"
            result[sshKey] = preferences.bridgedSSH ? "1" : "0"
            result.removeValue(forKey: PortForwardPolicy.environmentKey)
        }
        return result
    }
}

struct VMBridgeInterface: Equatable {
    let name: String
    let title: String
    let isWiFi: Bool
}

enum VMBridgeInterfaces {
    static func available() -> [VMBridgeInterface] {
        guard let resources = Bundle.main.resourceURL else { return [] }
        let helper = resources.appendingPathComponent("network/omarchy-network-supervisor")
        let process = Process()
        let pipe = Pipe()
        process.executableURL = helper
        process.arguments = ["--interfaces"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return [] }
        let hostInterfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        return text.split(separator: "\n").map(String.init).filter(VMNetworkPolicy.validInterface).map { name in
            let host = hostInterfaces.first { (SCNetworkInterfaceGetBSDName($0) as String?) == name }
            let label = host.flatMap { SCNetworkInterfaceGetLocalizedDisplayName($0) as String? } ?? name
            let wifi = host.map { SCNetworkInterfaceGetInterfaceType($0) == kSCNetworkInterfaceTypeIEEE80211 } ?? false
            return VMBridgeInterface(name: name, title: "\(label) (\(name))", isWiFi: wifi)
        }
    }
}

enum NetworkStartupFailure {
    static func message(standardError: String) -> String? {
        if standardError.contains("The selected bridge interface is unavailable.") {
            return "The selected network adapter is unavailable. Reconnect it, or open Networking and select another adapter or Shared connection (NAT), then try again."
        }
        if standardError.contains("Another bridged session is still active or finishing cleanup.") ||
            standardError.contains("Another bridged Try Omarchy session is active, or its lock is unavailable.") {
            return "Another bridged Omarchy VM is running or finishing shutdown. Shut it down and wait a moment, or choose NAT for this VM."
        }
        if standardError.contains("Bridged networking could not start.") {
            return "Bridged networking could not start. Shut down any bridged Omarchy VM, then use Set Up / Repair Networking, or choose NAT."
        }
        return nil
    }
}
