import Darwin
import Foundation

/// A kit's version: the release it was built for, `v1.2.3`, or `development`
/// for a kit built from anything but an exact release tag. Releases compare by
/// their numbers. A development kit compares newer than every release, so an
/// app that embeds one keeps it.
public enum TryOmarchyKitVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    case release(major: Int, minor: Int, patch: Int)
    case development

    public init?(_ text: String) {
        if text == "development" {
            self = .development
            return
        }
        guard text.hasPrefix("v") else { return nil }
        let parts = text.dropFirst().split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard (1...9).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  part == "0" || part.first != "0", let number = Int(part)
            else { return nil }
            numbers.append(number)
        }
        self = .release(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }

    public var isDevelopment: Bool { self == .development }

    public var description: String {
        switch self {
        case let .release(major, minor, patch): "v\(major).\(minor).\(patch)"
        case .development: "development"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.release(a, b, c), .release(x, y, z)): (a, b, c) < (x, y, z)
        case (.release, .development): true
        case (.development, _): false
        }
    }
}

/// What a kit can do beyond the run-mode protocol's version, so that an app
/// asks only for what the kit it runs knows. A kit that predates a
/// capability refuses a configuration that asks for it.
public enum TryOmarchyKitCapability: String, CaseIterable, Sendable {
    case nativeExports = "native-exports"
}

public enum TryOmarchyKitManifestError: Error, Equatable, Sendable {
    /// The kit has no manifest: it predates them, or it is damaged.
    case missing
    case invalid
}

/// The kit's `TryOmarchyKit.manifestPath`, which build-kit.sh writes into
/// every kit and each release also publishes as `TryOmarchyKit.json`. Keys a
/// reader does not know are ignored; `format` changes only when a known key
/// changes meaning.
public struct TryOmarchyKitManifest: Equatable, Sendable {
    public static let fileName = "kit.json"
    public static let format = 1
    public static let maximumBytes = 65_536

    public let version: TryOmarchyKitVersion
    /// The run-mode protocol the kit's helper speaks (`VMRunProtocol.version`).
    public let runProtocolVersion: Int
    public let buildDate: Date
    /// Names this client does not know are dropped.
    public let capabilities: Set<TryOmarchyKitCapability>

    public init(version: TryOmarchyKitVersion, runProtocolVersion: Int, buildDate: Date,
                capabilities: Set<TryOmarchyKitCapability> = []) {
        self.version = version
        self.runProtocolVersion = runProtocolVersion
        self.buildDate = buildDate
        self.capabilities = capabilities
    }

    public func supports(_ capability: TryOmarchyKitCapability) -> Bool { capabilities.contains(capability) }

    /// Whether this client library can run the kit.
    public var isSupported: Bool { runProtocolVersion == VMRunProtocol.version }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              VMRunLine.integer(object["format"]) == format,
              let versionText = object["version"] as? String,
              let version = TryOmarchyKitVersion(versionText),
              let runProtocolVersion = VMRunLine.integer(object["runProtocolVersion"]), runProtocolVersion >= 1,
              let dateText = object["buildDate"] as? String,
              dateText.utf8.count == 20,
              let buildDate = ISO8601DateFormatter().date(from: dateText)
        else { throw TryOmarchyKitManifestError.invalid }
        var capabilities: Set<TryOmarchyKitCapability> = []
        if let value = object["capabilities"] {
            guard let names = value as? [String] else { throw TryOmarchyKitManifestError.invalid }
            capabilities = Set(names.compactMap(TryOmarchyKitCapability.init(rawValue:)))
        }
        return Self(version: version, runProtocolVersion: runProtocolVersion, buildDate: buildDate,
                    capabilities: capabilities)
    }
}

extension TryOmarchyKit {
    public var manifestURL: URL {
        bundleURL.appendingPathComponent(Self.manifestPath, isDirectory: false)
    }

    public func manifest() throws -> TryOmarchyKitManifest {
        var information = stat()
        guard lstat(manifestURL.path, &information) == 0 else { throw TryOmarchyKitManifestError.missing }
        guard information.st_mode & S_IFMT == S_IFREG, information.st_size <= TryOmarchyKitManifest.maximumBytes,
              let data = try? Data(contentsOf: manifestURL)
        else { throw TryOmarchyKitManifestError.invalid }
        return try TryOmarchyKitManifest.decode(data)
    }
}
