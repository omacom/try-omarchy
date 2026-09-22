import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Mac app release checks", .serialized)
@MainActor
struct AppReleaseTests {
    private func installed(_ version: String) -> InstalledAppRelease {
        InstalledAppRelease(info: [
            "CFBundleShortVersionString": version,
            "CFBundleVersion": "321",
            "TryOmarchyBuildDescribe": "v\(version)",
        ])
    }

    private func release(_ version: String = "0.5.0") throws -> AppRelease {
        try AppRelease.decode(payload(tag: "v\(version)"))
    }

    private func payload(
        tag: String = "v0.5.0", draft: Bool = false, prerelease: Bool = false,
        assetName: String = "TryOmarchy.dmg", assetState: String = "uploaded"
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "draft": draft, "prerelease": prerelease,
            "html_url": "https://unrelated.example/download",
            "assets": [["name": assetName, "state": assetState]],
        ])
    }

    private func withPreferences(_ body: (AppReleasePreferences) async throws -> Void) async rethrows {
        let suite = "AppReleaseTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try await body(AppReleasePreferences(defaults: defaults))
    }

    @Test("stable versions compare numerically and reject ambiguous versions")
    func versionComparison() throws {
        #expect(try #require(AppReleaseVersion("0.10.0")) > #require(AppReleaseVersion("0.9.9")))
        #expect(try #require(AppReleaseVersion("1.0.0")) > #require(AppReleaseVersion("0.99.99")))
        for invalid in ["", "1.2", "v1.2.3", "01.2.3", "1.2.3-beta", "1.2.3+build", "-1.2.3", "1.2.3\n", "１.2.3", "999999999999999999999.0.0"] {
            #expect(AppReleaseVersion(invalid) == nil)
        }
    }

    @Test("legacy and development metadata never claim an installed stable release")
    func installedIdentity() {
        #expect(installed("0.5.0").label == "Version 0.5.0 (321)")
        let legacy = InstalledAppRelease(info: ["CFBundleShortVersionString": "0.4.0", "CFBundleVersion": "5"])
        #expect(legacy.version == nil)
        #expect(legacy.label == "Installed release unknown")
        for describe in ["v0.5.0-2-gabc", "v0.5.0-dirty", "v0.6.0"] {
            let build = InstalledAppRelease(info: ["CFBundleShortVersionString": "0.5.0", "TryOmarchyBuildDescribe": describe])
            #expect(build.version == nil)
        }
    }

    @Test("only published stable releases with an uploaded Mac app are accepted")
    func releaseValidation() throws {
        let latest = try release()
        #expect(latest.url.absoluteString == "https://github.com/omacom/try-omarchy/releases/tag/v0.5.0")
        for data in [
            try payload(draft: true), try payload(prerelease: true),
            try payload(tag: "v0.5.0-beta"), try payload(tag: "0.5.0"),
            try payload(assetName: "source.zip"), try payload(assetState: "starter"),
        ] {
            #expect(throws: AppReleaseError.self) { try AppRelease.decode(data) }
        }
        #expect(throws: DecodingError.self) { try AppRelease.decode(Data("{}".utf8)) }
    }

    @Test("current and newer installed builds are not offered a downgrade")
    func updateDecision() throws {
        let latest = try release()
        #expect(AppReleaseCheckState.result(installed: installed("0.4.1"), latest: latest) == .available(latest))
        #expect(AppReleaseCheckState.result(installed: installed("0.5.0"), latest: latest) == .current)
        #expect(AppReleaseCheckState.result(installed: installed("0.6.0"), latest: latest) == .current)
        #expect(AppReleaseCheckState.result(installed: InstalledAppRelease(info: [:]), latest: latest) == .unknownInstalledVersion(latest))
    }

    @Test("automatic checks are opt-in and rate limited, including after failures")
    func checkSchedule() async throws {
        await withPreferences { preferences in
            let now = Date(timeIntervalSince1970: 1_000_000)
            #expect(!preferences.shouldCheckAutomatically(now: now))
            preferences.automaticChecks = true
            #expect(preferences.shouldCheckAutomatically(now: now))
            preferences.recordAttempt(at: now)
            #expect(!preferences.shouldCheckAutomatically(now: now.addingTimeInterval(86399)))
            #expect(preferences.shouldCheckAutomatically(now: now.addingTimeInterval(86400)))
            #expect(preferences.shouldCheckAutomatically(now: now.addingTimeInterval(-1)))
            preferences.automaticChecks = false
            #expect(!preferences.shouldCheckAutomatically(now: now.addingTimeInterval(86400)))
        }
    }

    @Test("manual checks work with automatic checks off and duplicate requests share the result")
    func manualCheck() async throws {
        let latest = try release()
        await withPreferences { preferences in
            var requests = 0
            let checker = AppReleaseChecker(installed: installed("0.4.1"), preferences: preferences, fetch: {
                requests += 1
                return latest
            })
            checker.checkAutomaticallyIfDue()
            #expect(checker.state == .idle)
            #expect(checker.menuTitle == "Check for Updates…")
            let first = checker.check()
            let second = checker.check()
            #expect(checker.state == .checking)
            await first.value
            await second.value
            #expect(requests == 1)
            #expect(checker.state == .available(latest))
            #expect(checker.menuTitle == "Update Available…")
            #expect(!preferences.automaticChecks)
            // Keep the notification on subsequent launches within the daily interval.
            let reopened = AppReleaseChecker(installed: installed("0.4.1"), preferences: preferences)
            #expect(reopened.state == .available(latest))
        }
    }

    @Test("offline failures are recoverable and manual retries bypass the daily schedule")
    func offlineRetry() async throws {
        let latest = try release()
        await withPreferences { preferences in
            var offline = true
            let checker = AppReleaseChecker(installed: installed("0.4.1"), preferences: preferences, fetch: {
                if offline { throw URLError(.notConnectedToInternet) }
                return latest
            })
            await checker.check().value
            guard case .failed = checker.state else {
                Issue.record("Expected an offline failure")
                return
            }
            #expect(checker.state.releaseURL == AppRelease.releasesURL)
            #expect(checker.menuTitle == "Check for Updates…")
            offline = false
            await checker.check().value
            #expect(checker.state == .available(latest))
        }
    }

    @Test("cached update notifications survive automatic check failures until a successful refresh")
    func cachedUpdateSurvivesFailure() async throws {
        let cached = try release()
        let refreshed = try release("0.4.1")
        await withPreferences { preferences in
            let now = Date(timeIntervalSince1970: 1_000_000)
            preferences.latestRelease = cached
            preferences.automaticChecks = true
            var offline = true
            var requests = 0
            let checker = AppReleaseChecker(
                installed: installed("0.4.1"), preferences: preferences, now: { now },
                fetch: {
                    requests += 1
                    if offline { throw URLError(.notConnectedToInternet) }
                    return refreshed
                }
            )
            var observedTitles: [String] = []
            checker.onChange = { observedTitles.append(checker.menuTitle) }
            defer { checker.onChange = nil }
            #expect(checker.menuTitle == "Update Available…")
            checker.checkAutomaticallyIfDue()
            #expect(checker.state == .checking)
            #expect(checker.menuTitle == "Update Available…")
            await checker.check().value
            guard case .failed = checker.state else {
                Issue.record("Expected an offline failure")
                return
            }
            #expect(checker.menuTitle == "Update Available…")
            #expect(observedTitles == ["Update Available…", "Update Available…"])
            #expect(preferences.latestRelease == cached)
            #expect(!preferences.shouldCheckAutomatically(now: now))
            #expect(requests == 1)

            offline = false
            await checker.check().value
            #expect(checker.state == .current)
            #expect(checker.menuTitle == "Check for Updates…")
            #expect(preferences.latestRelease == refreshed)
            #expect(observedTitles.last == "Check for Updates…")
        }
    }

    @Test("cached releases only notify when newer than a known installed version")
    func cachedNotificationRequiresNewerRelease() async throws {
        let cached = try release()
        await withPreferences { preferences in
            preferences.latestRelease = cached
            for identity in [installed("0.5.0"), installed("0.6.0"), InstalledAppRelease(info: [:])] {
                let checker = AppReleaseChecker(installed: identity, preferences: preferences, fetch: {
                    throw URLError(.notConnectedToInternet)
                })
                #expect(checker.menuTitle == "Check for Updates…")
                await checker.check().value
                #expect(checker.menuTitle == "Check for Updates…")
            }
        }
    }

    @Test("HTTP failures are reported and malformed responses are rejected")
    func networkResponses() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReleaseResponseProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        ReleaseResponseProtocol.body = try payload()
        ReleaseResponseProtocol.status = 200
        #expect(try await AppReleaseChecker.fetchLatest(session: session) == release())
        for status in [403, 429, 500] {
            ReleaseResponseProtocol.status = status
            await #expect(throws: AppReleaseError.self) {
                try await AppReleaseChecker.fetchLatest(session: session)
            }
        }
        ReleaseResponseProtocol.status = 200
        ReleaseResponseProtocol.body = Data("not JSON".utf8)
        await #expect(throws: DecodingError.self) {
            try await AppReleaseChecker.fetchLatest(session: session)
        }
    }
}

// The containing suite is serialized; no live network or timing delays are used.
private final class ReleaseResponseProtocol: URLProtocol {
    static var status = 200
    static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
