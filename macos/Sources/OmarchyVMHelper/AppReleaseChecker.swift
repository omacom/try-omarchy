import Foundation

@MainActor
final class AppReleaseChecker {
    typealias Fetch = () async throws -> AppRelease
    let installed: InstalledAppRelease
    let preferences: AppReleasePreferences
    private let fetch: Fetch
    private let now: () -> Date
    private var task: Task<Void, Never>?
    var onChange: (() -> Void)?
    private(set) var state = AppReleaseCheckState.idle {
        didSet { onChange?() }
    }

    // Request progress and failures must not hide an already discovered update.
    var menuTitle: String {
        guard let latest = preferences.latestRelease else { return "Check for Updates…" }
        return AppReleaseCheckState.result(installed: installed, latest: latest).menuTitle
    }

    init(
        installed: InstalledAppRelease = .current,
        preferences: AppReleasePreferences = AppReleasePreferences(),
        now: @escaping () -> Date = Date.init,
        fetch: @escaping Fetch = { try await AppReleaseChecker.fetchLatest() }
    ) {
        self.installed = installed
        self.preferences = preferences
        self.now = now
        self.fetch = fetch
        if let latest = preferences.latestRelease {
            state = .result(installed: installed, latest: latest)
        }
    }

    func checkAutomaticallyIfDue() {
        guard preferences.shouldCheckAutomatically(now: now()) else { return }
        check()
    }

    @discardableResult
    func check() -> Task<Void, Never> {
        if let task { return task }
        preferences.recordAttempt(at: now())
        state = .checking
        let pending = Task { [weak self] in
            guard let self else { return }
            defer { task = nil }
            do {
                let latest = try await fetch()
                preferences.latestRelease = latest
                state = .result(installed: installed, latest: latest)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
        task = pending
        return pending
    }

    static func fetchLatest(session: URLSession? = nil) async throws -> AppRelease {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let client = session ?? URLSession(configuration: configuration)
        defer { if session == nil { client.finishTasksAndInvalidate() } }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/omacom/try-omarchy/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Try-Omarchy-Release-Check", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await client.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw AppReleaseError.response((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try AppRelease.decode(data)
    }
}
