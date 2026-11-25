import AppKit
import Sparkle

/// What an update does about the VM before it replaces the app.
enum AppUpdateStep: Equatable {
    case install
    case shutDownFirst
    case wait

    static func next(
        sessionRunning: Bool, reachedStart: Bool, stopping: Bool, downloading: Bool, changingStorage: Bool,
        otherInstances: Bool
    ) -> Self {
        // Sparkle would quit every instance of the app, whatever it is doing.
        if downloading || changingStorage || otherInstances { return .wait }
        guard sessionRunning else { return .install }
        return reachedStart && !stopping ? .shutDownFirst : .wait
    }
}

/// Finds, verifies and installs signed app updates with Sparkle
/// (docs/app-updates.md). It stays off until the bundle names both a feed and
/// the key that signs its updates, so development builds keep only the GitHub
/// release check, and the kit, which has no Sparkle, never reaches it.
@MainActor
final class AppUpdater: NSObject {
    nonisolated static let configurationKeys = ["SUFeedURL", "SUPublicEDKey"]

    nonisolated static func isConfigured(_ info: [String: Any]) -> Bool {
        configurationKeys.allSatisfy {
            (info[$0] as? String).map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? false
        }
    }

    /// From the choice to update until Sparkle is done: the app may quit at any moment.
    private(set) var isUpdating = false
    /// Whether nothing would be interrupted by replacing the app.
    var canReplaceApp: () -> Bool = { true }

    private let installed: AppReleaseVersion
    private var updater: SPUUpdater!
    private var probe: CheckedContinuation<AppRelease, Error>?
    private var found: SUAppcastItem?
    private var updateRequested = false
    private var postponedInstallation: (() -> Void)?

    init?(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        guard Self.isConfigured(info), NSClassFromString("SPUUpdater") != nil,
              let installed = InstalledAppRelease(info: info).version else { return nil }
        self.installed = installed
        super.init()
        let updater = SPUUpdater(
            hostBundle: .main, applicationBundle: .main,
            userDriver: AppUpdateDriver(), delegate: self
        )
        do { try updater.start() } catch {
            fputs("[updates] \(error.localizedDescription)\n", stderr)
            return nil
        }
        self.updater = updater
    }

    /// The newest release this Mac can install; the installed one when there is none.
    func latestRelease() async throws -> AppRelease {
        guard probe == nil, !updater.sessionInProgress else { throw AppUpdaterError.busy }
        found = nil
        return try await withCheckedThrowingContinuation {
            probe = $0
            updater.checkForUpdateInformation()
        }
    }

    func update() {
        isUpdating = true
        // A check that is under way finishes first; Sparkle runs one at a time.
        if probe != nil { updateRequested = true } else { updater.checkForUpdates() }
    }

    func resumePostponedInstallation() {
        guard let postponedInstallation, canReplaceApp() else { return }
        self.postponedInstallation = nil
        postponedInstallation()
    }

    static func release(_ displayVersion: String) throws -> AppRelease {
        guard let version = AppReleaseVersion(displayVersion) else { throw AppReleaseError.invalidRelease }
        return AppRelease(version: version)
    }

    private func probeResult(_ error: Error?) -> Result<AppRelease, Error> {
        if let found { return Result { try Self.release(found.displayVersionString) } }
        if let error = error as NSError?, error.domain != SUSparkleErrorDomain || error.code != SUError.noUpdateError.rawValue {
            return .failure(error)
        }
        return .success(AppRelease(version: installed))
    }
}

enum AppUpdaterError: LocalizedError {
    case busy
    case notRequested

    var errorDescription: String? {
        switch self {
        case .busy: "An update is already under way."
        case .notRequested: "Updates are installed only when you choose to."
        }
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    /// Sparkle lets a preference replace the bundle's feed and turn on its own
    /// schedule; neither may change where updates come from or who asks for them.
    func feedURLString(for updater: SPUUpdater) -> String? {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if updateCheck == .updatesInBackground { throw AppUpdaterError.notRequested }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        found = item
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if updateCheck == .updateInformation {
            probe?.resume(with: probeResult(error))
            probe = nil
            if updateRequested {
                updateRequested = false
                updater.checkForUpdates()
            }
        } else {
            isUpdating = false
            postponedInstallation = nil
        }
    }

    /// AppKit refuses to quit while a sheet is open, and the update would wait for it unseen.
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        for window in NSApp.windows { window.preventsApplicationTerminationWhenModal = false }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard !canReplaceApp() else { return false }
        postponedInstallation = installHandler
        return true
    }
}

/// Sparkle's own windows for progress and errors, without its questions: the
/// launcher asks once, and asks to shut Omarchy down when it runs.
@MainActor
private final class AppUpdateDriver: NSObject, SPUUserDriver {
    private let standard = SPUStandardUserDriver(hostBundle: .main, delegate: nil)

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        standard.dismissUpdateInstallation()
        reply(.install)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        reply(.install)
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        standard.show(request, reply: reply)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        standard.showUserInitiatedUpdateCheck(cancellation: cancellation)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        standard.showUpdaterError(error, acknowledgement: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        standard.showDownloadInitiated(cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        standard.showDownloadDidReceiveData(ofLength: length)
    }

    func showDownloadDidStartExtractingUpdate() {
        standard.showDownloadDidStartExtractingUpdate()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        standard.showExtractionReceivedProgress(progress)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        standard.showInstallingUpdate(
            withApplicationTerminated: applicationTerminated, retryTerminatingApplication: retryTerminatingApplication
        )
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
    }

    func dismissUpdateInstallation() {
        standard.dismissUpdateInstallation()
    }

    func showUpdateInFocus() {
        (standard as SPUUserDriver).showUpdateInFocus?()
    }
}
