import AppKit
import Observation
import SwiftUI

@MainActor
enum AppReleasePrompt {
    static func alert(for release: AppRelease) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Try Omarchy \(release.version) is available"
        alert.informativeText = "Download opens the release page on GitHub. Shut down Omarchy before replacing the app; your VM and settings are kept.\n\nSkip hides reminders for this version."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Skip").keyEquivalent = "\u{1b}"
        return alert
    }
}

/// What the updates window shows, copied from the checker on every change.
@MainActor
@Observable
final class AppReleaseWindowState {
    var installedLabel = ""
    var checkState = AppReleaseCheckState.idle
    var automaticChecks = false
}

@MainActor
struct AppReleaseWindowActions {
    var checkNow: () -> Void = {}
    var openRelease: () -> Void = {}
    var setAutomaticChecks: (Bool) -> Void = { _ in }
}

@MainActor
final class AppReleaseWindow: NSObject {
    static let contentSize = NSSize(width: 500, height: 440)

    private let checker: AppReleaseChecker
    private let window: NSWindow
    let state = AppReleaseWindowState()

    var isVisible: Bool { window.isVisible }

    init(checker: AppReleaseChecker) {
        self.checker = checker
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false
        )
        super.init()
        window.title = "Try Omarchy Updates"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false

        let actions = AppReleaseWindowActions(
            checkNow: { [weak self] in self?.checker.check() },
            openRelease: { [weak self] in
                guard let self else { return }
                NSWorkspace.shared.open(checker.state.releaseURL)
            },
            setAutomaticChecks: { [weak self] enabled in
                guard let self else { return }
                checker.preferences.automaticChecks = enabled
                checker.checkAutomaticallyIfDue()
                refresh()
            }
        )
        let host = NSHostingController(rootView: AppReleaseView(state: state, actions: actions))
        host.sceneBridgingOptions = []
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(Self.contentSize)
        refresh()
    }

    func show() {
        refresh()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        checker.check()
    }

    func refresh() {
        state.installedLabel = checker.installed.label
        state.checkState = checker.state
        state.automaticChecks = checker.preferences.automaticChecks
        // Reading the result here already serves as the update notification.
        if window.isVisible, case .available(let release) = checker.state {
            checker.acknowledgeRelease(release)
        }
    }
}

// MARK: - View

extension AppReleaseCheckState {
    var title: String {
        switch self {
        case .idle: "Check for Updates"
        case .checking: "Checking for Updates"
        case .available(let release): "Version \(release.version) Available"
        case .current: "Try Omarchy Is Up to Date"
        case .unknownInstalledVersion(let release): "Latest Release Is \(release.version)"
        case .failed: "Couldn’t Check for Updates"
        }
    }

    var detail: String {
        switch self {
        case .idle: "Looks for the latest stable release on GitHub."
        case .checking: "Contacting GitHub"
        case .available: "Review its release notes and macOS requirements before downloading."
        case .current: "No newer stable release was found."
        case .unknownInstalledVersion:
            "This build doesn’t identify its installed release reliably, so versions can’t be compared."
        case .failed(let message): "\(message) You can still launch Omarchy."
        }
    }

    var icon: SettingIcon {
        switch self {
        case .idle, .checking: SettingIcon("arrow.triangle.2.circlepath", .gray)
        case .available: SettingIcon("arrow.down", .blue)
        case .current: SettingIcon("checkmark", .green)
        case .unknownInstalledVersion: SettingIcon("questionmark", .gray)
        case .failed: SettingIcon("exclamationmark.triangle.fill", .orange)
        }
    }
}

struct AppReleaseView: View {
    @Bindable var state: AppReleaseWindowState
    let actions: AppReleaseWindowActions

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                OmarchyAppTile(size: 72)
                    .padding(.bottom, 6)
                Text("Try Omarchy")
                    .font(.title2.weight(.semibold))
                Text(state.installedLabel)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(.top, 40)

            Form {
                Section {
                    statusRow
                    SettingRow(
                        icon: SettingIcon("doc.text.fill", .gray),
                        title: "Release Notes",
                        detail: ["Changes, downloads and macOS requirements on GitHub."]
                    ) {
                        Button("View…", action: actions.openRelease)
                            .accessibilityIdentifier("app-release-notes-button")
                    }
                }

                Section {
                    SettingRow(
                        icon: SettingIcon("clock.arrow.circlepath", .blue),
                        title: "Check Automatically",
                        detail: ["At most once a day, when you open the app."]
                    ) {
                        Toggle("Check Automatically", isOn: Binding(
                            get: { state.automaticChecks },
                            set: { actions.setAutomaticChecks($0) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("app-release-automatic-toggle")
                    }
                } footer: {
                    SectionNote("Updates are never downloaded or installed automatically. To update, shut down Omarchy and replace the Mac app; your VM and settings are kept, and the guest updates separately.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea(.container, edges: .top)
    }

    private var statusRow: some View {
        SettingRow(
            icon: state.checkState.icon,
            title: state.checkState.title,
            detail: [state.checkState.detail]
        ) {
            switch state.checkState {
            case .checking:
                ProgressView().controlSize(.small)
            case .available:
                Button("Download…", action: actions.openRelease)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("app-release-download-button")
            default:
                Button("Check Now", action: actions.checkNow)
                    .accessibilityIdentifier("app-release-check-button")
            }
        }
    }
}
