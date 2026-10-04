import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Boot fix consent and results")
struct GuestBootFixTests {
    private let identity = String(repeating: "a", count: 64)

    private func report(state: String = "complete", outcome: String = "current") -> GuestBootFixReport {
        GuestBootFixReport(schema: 1, type: "boot-fixes", identity: identity, state: state,
                           components: ["clipboard": outcome, "screensaver": outcome, "alacritty": outcome])
    }

    @Test("Update requires review; skipping requires its own confirmation")
    func consent() {
        var skipConfirmations = 0
        for choice in [GuestBootFixChoice.update, .cancel] {
            #expect(GuestBootFixLaunchGate.decide(review: { choice }, confirmSkip: {
                skipConfirmations += 1
                return true
            }) == choice)
        }
        #expect(skipConfirmations == 0)
        #expect(GuestBootFixLaunchGate.decide(review: { .skip }, confirmSkip: { true }) == .skip)
        #expect(GuestBootFixLaunchGate.decide(review: { .skip }, confirmSkip: { false }) == .cancel)
    }

    @Test("Existing disks offer updates before their first check of a new bundle")
    func updatePolicy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("boot-fixes-123.json")
        #expect(!GuestBootFixCache.needsUpdate(cacheURL: nil, expectedIdentity: identity))
        #expect(!GuestBootFixCache.needsUpdate(cacheURL: url, expectedIdentity: nil))
        #expect(GuestBootFixCache.needsUpdate(cacheURL: url, expectedIdentity: identity))
        #expect(GuestBootFixCache.needsReview(cacheURL: url, expectedIdentity: identity))
        for state in ["checking", "running", "skipped", "failed", "recovery-required", "unconfirmed", "complete"] {
            let value = GuestBootFixCache(checkedAt: Date(), report: report(state: state))
            try JSONEncoder().encode(value).write(to: url)
            #expect(GuestBootFixCache.needsUpdate(cacheURL: url, expectedIdentity: identity)
                == !["complete", "skipped"].contains(state))
        }
        let pending = GuestBootFixCache(checkedAt: Date(), report: report(state: "skipped", outcome: "pending"))
        try JSONEncoder().encode(pending).write(to: url)
        #expect(GuestBootFixCache.needsUpdate(cacheURL: url, expectedIdentity: identity))
        #expect(GuestBootFixCache.needsUpdate(cacheURL: url, expectedIdentity: String(repeating: "b", count: 64)))
        try Data("{}".utf8).write(to: url)
        #expect(GuestBootFixCache.needsUpdate(cacheURL: url, expectedIdentity: identity))
        #expect(GuestBootFixCache.consent(cacheURL: url, identity: identity) == "\(identity):123")
    }

    @Test("Skip Launcher shows the launcher for first-time review and resumes afterwards")
    func automaticStartup() throws {
        #expect(StartupPolicy.shouldStartAutomatically(isEnabled: true, hasExistingVM: true, optionKeyHeld: false, initialArguments: []))
        #expect(!GuestBootFixCache.needsUpdate(cacheURL: nil, expectedIdentity: identity))
        #expect(!StartupPolicy.shouldStartAutomatically(isEnabled: true, hasExistingVM: true,
            optionKeyHeld: false, initialArguments: [], requiresVMFixReview: true))
        for outcome in ["current", "applied", "preserved", "unavailable"] {
            #expect(!report(outcome: outcome).needsUpdate)
            #expect(!report(outcome: outcome).needsAttention)
        }
    }

    @Test("Only unsuccessful reports need recovery or retry attention")
    func resultAttention() {
        for state in ["checking", "running", "complete", "skipped"] {
            #expect(!report(state: state).needsAttention)
        }
        for state in ["failed", "recovery-required", "unconfirmed"] {
            #expect(report(state: state).needsAttention)
        }
    }

    @Test("Approved updates report a result only after completion")
    func updateResult() throws {
        for state in ["checking", "running"] {
            #expect(GuestBootFixResult(report: report(state: state)) == nil)
        }
        for outcome in ["current", "applied"] {
            let result = try #require(GuestBootFixResult(report: report(outcome: outcome)))
            #expect(!result.isWarning)
        }
        let skippedCurrent = try #require(GuestBootFixResult(report: report(state: "skipped")))
        #expect(!skippedCurrent.isWarning)
        let skippedPending = try #require(GuestBootFixResult(report: report(state: "skipped", outcome: "pending")))
        #expect(skippedPending.isWarning)
        for state in ["failed", "recovery-required", "unconfirmed"] {
            let result = try #require(GuestBootFixResult(report: report(state: state)))
            #expect(result.isWarning)
        }
    }

    @Test("Partial updates name only the items that could not be updated")
    func partialUpdateResult() throws {
        for outcome in ["preserved", "unavailable"] {
            let partial = GuestBootFixReport(schema: 1, type: "boot-fixes", identity: identity, state: "complete",
                components: ["clipboard": "applied", "battery": outcome, "touch-id": "current"])
            let result = try #require(GuestBootFixResult(report: partial))
            #expect(result.isWarning)
            #expect(result.message.contains("Battery widget"))
            #expect(!result.message.contains("Clipboard"))
            #expect(!result.message.contains("Touch ID"))
        }
        let recovery = try #require(GuestBootFixResult(report: report(state: "recovery-required")))
        #expect(!recovery.message.contains("changes were restored"))
        let unconfirmed = try #require(GuestBootFixResult(report: report(state: "unconfirmed")))
        #expect(!unconfirmed.message.contains("up to date"))
    }

    @Test("A reviewed bundle never nags again after failure, skipping, or interrupted startup")
    func reviewSurvivesResults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("boot-fixes-123.json")
        try GuestBootFixCache.retain(report(state: "skipped", outcome: "pending"), cacheURL: url)
        #expect(GuestBootFixCache.needsReview(cacheURL: url, expectedIdentity: identity))
        try GuestBootFixCache.recordReview(cacheURL: url, identity: identity)
        for state in ["checking", "running", "failed", "recovery-required", "unconfirmed", "skipped"] {
            try GuestBootFixCache.retain(report(state: state, outcome: "pending"), cacheURL: url)
            #expect(GuestBootFixCache.needsUpdate(cacheURL: url, expectedIdentity: identity))
            #expect(!GuestBootFixCache.needsReview(cacheURL: url, expectedIdentity: identity))
            #expect(GuestBootFixCache.needsReview(cacheURL: url, expectedIdentity: identity, manuallyRequested: true))
        }
        try GuestBootFixCache.retain(report(), cacheURL: url)
        #expect(!GuestBootFixCache.needsReview(cacheURL: url, expectedIdentity: identity, manuallyRequested: true))

        let nextIdentity = String(repeating: "b", count: 64)
        let next = GuestBootFixReport(schema: 1, type: "boot-fixes", identity: nextIdentity, state: "skipped",
                                     components: report(outcome: "pending").components)
        try GuestBootFixCache.retain(next, cacheURL: url)
        #expect(GuestBootFixCache.needsReview(cacheURL: url, expectedIdentity: nextIdentity))
        #expect(GuestBootFixCache.needsReview(cacheURL: url, expectedIdentity: identity, manuallyRequested: true))
        let anotherDisk = directory.appendingPathComponent("boot-fixes-456.json")
        try GuestBootFixCache.retain(report(state: "skipped", outcome: "pending"), cacheURL: anotherDisk)
        #expect(GuestBootFixCache.needsReview(cacheURL: anotherDisk, expectedIdentity: identity))
    }

    @Test("First-launch skip or cancellation is remembered before any guest report exists")
    func reviewBeforeFirstBoot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("boot-fixes-123.json")
        #expect(GuestBootFixCache.needsReview(cacheURL: url, expectedIdentity: identity))
        try GuestBootFixCache.recordReview(cacheURL: url, identity: identity)
        #expect(GuestBootFixCache.read(url) == nil)
        #expect(!GuestBootFixCache.needsReview(cacheURL: url, expectedIdentity: identity))
        #expect(GuestBootFixCache.needsReview(cacheURL: url, expectedIdentity: identity, manuallyRequested: true))
        #expect(GuestBootFixCache.needsReview(cacheURL: url, expectedIdentity: String(repeating: "b", count: 64)))
        #expect(GuestBootFixCache.needsReview(cacheURL: directory.appendingPathComponent("boot-fixes-456.json"), expectedIdentity: identity))
        try GuestBootFixCache.retain(report(state: "skipped", outcome: "pending"), cacheURL: url)
        #expect(!GuestBootFixCache.needsReview(cacheURL: url, expectedIdentity: identity))
    }

    @Test("Legacy failed updates stay manual even when later boots report pending work")
    func legacyFailedReview() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("boot-fixes-123.json")
        for state in ["checking", "running", "failed", "recovery-required", "unconfirmed"] {
            let legacy = GuestBootFixCache(checkedAt: Date(), report: report(state: state, outcome: "pending"))
            // Existing report files have no separate review acknowledgement.
            for marker in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where marker.pathExtension == "reviewed" {
                try FileManager.default.removeItem(at: marker)
            }
            try JSONEncoder().encode(legacy).write(to: url)
            #expect(!GuestBootFixCache.needsReview(cacheURL: url, expectedIdentity: identity))
            try GuestBootFixCache.retain(report(state: "skipped", outcome: "pending"), cacheURL: url)
            #expect(!GuestBootFixCache.needsReview(cacheURL: url, expectedIdentity: identity))
        }
    }

    @Test("Malformed, oversized, and incomplete success reports cannot establish completion")
    func decoding() throws {
        #expect(try GuestBootFixReport.decode(JSONEncoder().encode(report())) == report())
        for raw in [Data("{}".utf8), Data(repeating: 120, count: 4097),
                    try JSONEncoder().encode(report(outcome: "pending")),
                    try JSONEncoder().encode(report(outcome: "failed")),
                    try JSONEncoder().encode(report(state: "unknown"))] {
            #expect(throws: (any Error).self) { try GuestBootFixReport.decode(raw) }
        }
        let expanded = GuestBootFixReport(schema: 1, type: "boot-fixes", identity: identity, state: "running",
                                          components: GuestBootFixReport.pendingComponents)
        #expect(try GuestBootFixReport.decode(JSONEncoder().encode(expanded)) == expanded)
        #expect(expanded.detail.contains("Mac battery"))
        #expect(expanded.detail.contains("Clock recovery"))
        #expect(expanded.detail.contains("Ghostty terminal installer"))
        let previous = GuestBootFixReport(schema: 1, type: "boot-fixes", identity: identity, state: "complete",
            components: Dictionary(uniqueKeysWithValues: GuestBootFixReport.componentNames
                .filter { $0 != "ghostty" }.map { ($0, "current") }))
        #expect(try GuestBootFixReport.decode(JSONEncoder().encode(previous)) == previous)
        var current = previous.components
        current["ghostty"] = "applied"
        let migrated = GuestBootFixReport(schema: 1, type: "boot-fixes", identity: identity, state: "complete", components: current)
        #expect(try GuestBootFixReport.decode(JSONEncoder().encode(migrated)) == migrated)
        #expect(migrated.detail.contains("Ghostty terminal installer: applied and verified"))
        var unknown = expanded.components
        unknown["arbitrary-command"] = "current"
        #expect(throws: (any Error).self) {
            try GuestBootFixReport.decode(JSONEncoder().encode(GuestBootFixReport(schema: 1, type: "boot-fixes",
                identity: identity, state: "running", components: unknown)))
        }
    }

    @Test("Fragmented migration results stay separate from settings requests")
    func framing() throws {
        let data = try JSONEncoder().encode(report()) + Data([10])
        var buffer = SettingsRequestBuffer()
        let partial = buffer.consume(data.prefix(20))
        #expect(!partial)
        #expect(buffer.migrationReports.isEmpty)
        let settings = buffer.consume(data.dropFirst(20) + Data("open-settings\n".utf8))
        #expect(settings)
        #expect(buffer.migrationReports == [report()])
        let oversized = buffer.consume(Data(repeating: 120, count: 4097) + data)
        #expect(!oversized)
        #expect(buffer.migrationReports.isEmpty)
        let final = buffer.consume(data)
        #expect(!final)
        #expect(buffer.migrationReports == [report()])
    }

    @Test("A recovery failure never claims previous files were restored")
    func recoveryMessage() {
        #expect(report(state: "failed").summary.contains("restored"))
        #expect(!report(state: "recovery-required").summary.contains("restored"))
        #expect(report(outcome: "preserved").summary.contains("skipped"))
        #expect(report(outcome: "preserved").detail.contains("preserved"))
        #expect(report().summary(expectedIdentity: String(repeating: "b", count: 64)).contains("older bundle"))
    }
}
