import Foundation

/// Read-only view of powerd's persisted manual charging policy. This is an
/// undocumented macOS format: missing, changed, or unreadable data means unknown.
enum HostChargeLimit {
    static let policyURL = URL(fileURLWithPath: "/Library/Preferences/com.apple.powerd.charging.plist")

    static func capture() -> Int? {
        guard let data = try? Data(contentsOf: policyURL) else { return nil }
        return read(data)
    }

    static func read(_ data: Data) -> Int? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let archive = plist["policies"] as? Data,
              let decoder = try? NSKeyedUnarchiver(forReadingFrom: archive) else { return nil }
        decoder.decodingFailurePolicy = .setErrorAndReturn
        decoder.setClass(ChargingPolicy.self, forClassName: "ChargeCtrlPolicy")
        defer { decoder.finishDecoding() }
        guard let policies = decoder.decodeObject(
            of: [NSArray.self, ChargingPolicy.self, NSString.self],
            forKey: NSKeyedArchiveRootObjectKey
        ) as? [ChargingPolicy], decoder.error == nil else { return nil }
        return policies.filter {
            $0.reason == "manualChargeLimit" && !$0.terminated && (1..<100).contains($0.limit)
        }.map(\.limit).min()
    }
}

@objc(TryOmarchyHostChargingPolicy)
private final class ChargingPolicy: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let reason: String?
    let limit: Int
    let terminated: Bool

    required init?(coder: NSCoder) {
        reason = coder.decodeObject(of: NSString.self, forKey: "reason") as String?
        limit = coder.decodeInteger(forKey: "soclimit")
        terminated = coder.decodeBool(forKey: "terminated")
    }

    func encode(with coder: NSCoder) { preconditionFailure("Read-only charging policy") }
}
