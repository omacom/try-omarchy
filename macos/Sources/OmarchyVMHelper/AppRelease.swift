import Foundation

/// Stable release tags only; development and prerelease builds are not comparable.
struct AppReleaseVersion: Equatable, Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ value: String) {
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3,
              fields.allSatisfy({ field in
                  !field.isEmpty && field.allSatisfy({ $0 >= "0" && $0 <= "9" })
                      && (field.count == 1 || field.first != "0")
              }),
              let major = Int(fields[0]), let minor = Int(fields[1]), let patch = Int(fields[2]) else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

struct InstalledAppRelease: Equatable {
    let version: AppReleaseVersion?
    let label: String

    init(info: [String: Any]) {
        // Older bundles all reported 0.4.0 (5), regardless of their release.
        // Require the build provenance introduced by #223 before comparing.
        let describe = info["TryOmarchyBuildDescribe"] as? String
        let shortVersion = info["CFBundleShortVersionString"] as? String ?? ""
        if let parsed = AppReleaseVersion(shortVersion), describe == "v\(parsed)" {
            version = parsed
            let build = info["CFBundleVersion"] as? String
            label = "Version \(parsed)" + (build.map { " (\($0))" } ?? "")
        } else {
            version = nil
            label = describe.map { "Development build · \($0)" } ?? "Installed release unknown"
        }
    }

    static var current: Self { Self(info: Bundle.main.infoDictionary ?? [:]) }
}

struct AppRelease: Equatable {
    static let releasesURL = URL(string: "https://github.com/omacom/try-omarchy/releases")!
    let version: AppReleaseVersion
    let url: URL

    static func decode(_ data: Data) throws -> Self {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard !payload.draft, !payload.prerelease, payload.tagName.hasPrefix("v"),
              let version = AppReleaseVersion(String(payload.tagName.dropFirst())),
              payload.assets.contains(where: { $0.name == "TryOmarchy.dmg" && $0.state == "uploaded" }) else {
            throw AppReleaseError.invalidRelease
        }
        // Construct the project URL instead of opening an arbitrary URL from JSON.
        return Self(version: version, url: releasesURL.appendingPathComponent("tag/v\(version)"))
    }

    private struct Payload: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let state: String
        }
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case draft, prerelease, assets
        }
    }
}

enum AppReleaseError: LocalizedError {
    case invalidRelease
    case response(Int)

    var errorDescription: String? {
        switch self {
        case .invalidRelease:
            return "GitHub did not return a published stable release with a macOS download."
        case .response(let status):
            return status == 403 || status == 429
                ? "GitHub’s request limit was reached. Try again later or open the releases page."
                : "GitHub could not complete the check (HTTP \(status))."
        }
    }
}

enum AppReleaseCheckState: Equatable {
    case idle
    case checking
    case available(AppRelease)
    case current
    case unknownInstalledVersion(AppRelease)
    case failed(String)

    static func result(installed: InstalledAppRelease, latest: AppRelease) -> Self {
        guard let version = installed.version else { return .unknownInstalledVersion(latest) }
        return latest.version > version ? .available(latest) : .current
    }

    var message: String {
        switch self {
        case .idle: return "Check GitHub for the latest stable Mac app release."
        case .checking: return "Checking for updates…"
        case .available(let release): return "Try Omarchy \(release.version) is available. Review its release notes and macOS requirements before downloading."
        case .current: return "No newer stable release was found."
        case .unknownInstalledVersion(let release):
            return "The latest stable release is \(release.version). This build does not identify its installed release reliably, so versions cannot be compared."
        case .failed(let message): return "Couldn’t check for updates. \(message) You can still launch Omarchy."
        }
    }

    var releaseURL: URL {
        switch self {
        case .available(let release), .unknownInstalledVersion(let release): return release.url
        default: return AppRelease.releasesURL
        }
    }

    var menuTitle: String {
        if case .available = self { return "Update Available…" }
        return "Check for Updates…"
    }
}

struct AppReleasePreferences {
    private let defaults: UserDefaults
    private static let enabledKey = "appReleaseAutomaticChecks"
    private static let lastAttemptKey = "appReleaseLastCheckAttempt"
    private static let latestVersionKey = "appReleaseLatestVersion"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var automaticChecks: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    func shouldCheckAutomatically(now: Date) -> Bool {
        guard automaticChecks else { return false }
        guard let previous = defaults.object(forKey: Self.lastAttemptKey) as? Date else { return true }
        let elapsed = now.timeIntervalSince(previous)
        return elapsed < 0 || elapsed >= 24 * 60 * 60
    }

    func recordAttempt(at date: Date) { defaults.set(date, forKey: Self.lastAttemptKey) }

    var latestRelease: AppRelease? {
        get {
            guard let text = defaults.string(forKey: Self.latestVersionKey),
                  let version = AppReleaseVersion(text) else { return nil }
            return AppRelease(version: version, url: AppRelease.releasesURL.appendingPathComponent("tag/v\(version)"))
        }
        nonmutating set { defaults.set(newValue?.version.description, forKey: Self.latestVersionKey) }
    }
}
