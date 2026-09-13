import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Networking policy")
struct NetworkingTests {
    @Test("An unavailable adapter offers specific recovery even with a generic bridge error", arguments: [
        "[qemu-gpu] The selected bridge interface is unavailable. Choose another interface or NAT.",
        "The selected bridge interface is unavailable.\n[qemu-gpu] Bridged networking could not start."
    ])
    func unavailableAdapterStartupFailure(output: String) throws {
        let message = try #require(NetworkStartupFailure.message(standardError: output))
        #expect(message.contains("Reconnect it"))
        #expect(message.contains("Shared connection (NAT)"))
        #expect(!message.contains("Repair"))
        #expect(!message.contains("Reinstall"))
    }

    @Test("A concurrent bridge failure offers recovery without reinstalling")
    func concurrentStartupFailure() throws {
        let output = "Another bridged session is still active or finishing cleanup.\n[qemu-gpu] Bridged networking could not start."
        let message = try #require(NetworkStartupFailure.message(standardError: output))
        #expect(message.contains("Another bridged Omarchy VM"))
        #expect(message.contains("choose NAT"))
        #expect(!message.contains("Repair"))
        #expect(NetworkStartupFailure.message(standardError: "unrelated startup failure") == nil)
    }

    @Test("Wi-Fi compatibility follows host support and interface type")
    func automaticCompatibility() {
        #expect(VMNetworkPolicy.requiresWiFiCompatibility(isWiFi: true, supported: true))
        #expect(!VMNetworkPolicy.requiresWiFiCompatibility(isWiFi: false, supported: true))
        #expect(!VMNetworkPolicy.requiresWiFiCompatibility(isWiFi: true, supported: false))
        #expect(!VMNetworkPolicy.requiresWiFiCompatibility(isWiFi: false, supported: false))
    }

    @Test("NAT clears inherited bridge flags while retaining forwards")
    func natEnvironment() {
        let base = Dictionary(uniqueKeysWithValues: VMNetworkPolicy.keys.map { ($0, "inherited") })
            .merging([PortForwardPolicy.environmentKey: "tcp:2222:22", "KEEP": "yes"]) { _, new in new }
        let result = VMNetworkPolicy.environment(base: base, preferences: .init())
        #expect(result[VMNetworkPolicy.modeKey] == "nat")
        #expect(result[VMNetworkPolicy.interfaceKey] == nil)
        #expect(result[VMNetworkPolicy.compatibilityKey] == nil)
        #expect(result[VMNetworkPolicy.sshKey] == nil)
        #expect(result[PortForwardPolicy.environmentKey] == "tcp:2222:22")
        #expect(result["KEEP"] == "yes")
        #expect(result[VMNetworkPolicy.ownerKey] == String(ProcessInfo.processInfo.processIdentifier))
    }

    @Test("Bridging requires separate explicit SSH and compatibility choices")
    func bridgeEnvironment() {
        var preferences = VMNetworkPreferences(mode: .bridged, interface: "en0")
        let base = [PortForwardPolicy.environmentKey: "tcp:2222:22"]
        var result = VMNetworkPolicy.environment(base: base, preferences: preferences)
        #expect(result[PortForwardPolicy.environmentKey] == nil)
        #expect(result[VMNetworkPolicy.sshKey] == "0")
        #expect(result[VMNetworkPolicy.compatibilityKey] == "0")
        preferences.bridgedSSH = true
        preferences.wifiCompatibility = true
        result = VMNetworkPolicy.environment(base: base, preferences: preferences)
        #expect(result[VMNetworkPolicy.sshKey] == "1")
        #expect(result[VMNetworkPolicy.compatibilityKey] == "1")
        #expect(base[PortForwardPolicy.environmentKey] == "tcp:2222:22")
    }

    @Test("Preferences survive relaunch and malformed versions fall back to NAT")
    func persistence() throws {
        let name = "network-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = VMNetworkPreferenceStore(defaults: defaults)
        #expect(store.load() == VMNetworkPreferences())
        let preferences = VMNetworkPreferences(mode: .bridged, interface: "en0", wifiCompatibility: true, bridgedSSH: true)
        try store.save(preferences)
        #expect(VMNetworkPreferenceStore(defaults: defaults).load() == preferences)
        defaults.set(Data("{\"version\":99}".utf8), forKey: VMNetworkPreferenceStore.key)
        #expect(store.load() == VMNetworkPreferences())
        defaults.set(Data("invalid".utf8), forKey: VMNetworkPreferenceStore.key)
        #expect(store.load() == VMNetworkPreferences())
    }

    @Test("Interface arguments reject delimiters and shell syntax", arguments: ["", "../en0", "en0,mode=shared", "en0\n", "$(id)", "-en0", String(repeating: "a", count: 33)])
    func invalidInterfaces(_ interface: String) {
        #expect(!VMNetworkPolicy.validInterface(interface))
    }
}
