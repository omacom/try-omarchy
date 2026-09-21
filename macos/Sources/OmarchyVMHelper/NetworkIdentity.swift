import Foundation

struct VMNetworkIdentityAccess {
    var isEphemeral = false
    var read: () throws -> String
    var canReplace: () -> Bool = { false }
    var replace: (_ expected: String, _ proposed: String) throws -> String

    static let unavailable = Self(
        read: { "" },
        replace: { _, _ in throw HelperError.io("Start this VM once before changing its MAC address.") }
    )

    static func forLaunch(arguments: [String], operation: @escaping ([String]) throws -> String) -> Self {
        if arguments.first == QEMUGPUStorageOption.ephemeral.rawValue {
            return Self(isEphemeral: true, read: { "" }, replace: { _, _ in
                throw HelperError.io("Ephemeral VMs receive a new MAC address on each launch.")
            })
        }
        return Self(
            read: { try operation(["show"]) },
            canReplace: { (try? operation(["check"])) != nil },
            replace: { expected, proposed in try operation(["replace", expected, proposed]) }
        )
    }

    static func proposedMAC() -> String {
        "02:" + (0..<5).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined(separator: ":")
    }

    static func operation(_ arguments: [String], root: URL, resources: URL,
                          environment: [String: String], bundleIdentity: String?) throws -> String {
        guard let key = QEMUGPUStorageSpaceEstimate.storageKey(
            environment: environment, bundleIdentity: bundleIdentity
        ) else {
            throw HelperError.io("The VM workspace identity is unavailable.")
        }
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", resources.appendingPathComponent("scripts/network-identity.py").path,
                             arguments[0], root.path, key] + arguments.dropFirst()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let result = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let error = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw HelperError.io(error.isEmpty ? "The VM network identity could not be read." : error)
        }
        return result
    }
}
