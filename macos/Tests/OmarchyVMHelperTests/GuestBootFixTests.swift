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

    @Test("Only a complete matching result suppresses the next update offer")
    func updatePolicy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("boot-fixes-123.json")
        #expect(!GuestBootFixCache.needsUpdate(cacheURL: nil, expectedIdentity: identity))
        #expect(!GuestBootFixCache.needsUpdate(cacheURL: url, expectedIdentity: nil))
        #expect(GuestBootFixCache.needsUpdate(cacheURL: url, expectedIdentity: identity))
        for state in ["checking", "running", "skipped", "failed", "recovery-required", "unconfirmed", "complete"] {
            let value = GuestBootFixCache(checkedAt: Date(), report: report(state: state))
            try JSONEncoder().encode(value).write(to: url)
            #expect(GuestBootFixCache.needsUpdate(cacheURL: url, expectedIdentity: identity) == (state != "complete"))
        }
        #expect(GuestBootFixCache.needsUpdate(cacheURL: url, expectedIdentity: String(repeating: "b", count: 64)))
        #expect(GuestBootFixCache.consent(cacheURL: url, identity: identity) == "\(identity):123")
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
