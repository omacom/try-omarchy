import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Upstream-shell guest status")
struct ShellGuestStatusTests {
    @Test("a protocol 1 report decodes")
    func decodesReport() throws {
        let line = #"{"channel":"edge","kernel":{"installed":"7.2.8-11","running":"7.2.8-11-omarchy"},"omarchy":"4.0.0.r7024.g246f33a-1","package":"0.1.0-1","protocol":1}"#
        let report = try ShellGuestReport.decode(Data(line.utf8))
        #expect(report.package == "0.1.0-1")
        #expect(report.channel == "edge")
        #expect(report.kernel?.running == "7.2.8-11-omarchy")
        #expect(report.install == nil)
    }

    @Test("a newer guest protocol with unknown fields still decodes")
    func toleratesNewerGuests() throws {
        let line = #"{"protocol":2,"package":"0.2.0-1","future":{"anything":true}}"#
        #expect(try ShellGuestReport.decode(Data(line.utf8)).protocol == 2)
    }

    @Test("oversized, malformed and multi-line values are refused")
    func refusesBadReports() {
        #expect(throws: (any Error).self) { try ShellGuestReport.decode(Data(repeating: 32, count: 5000)) }
        #expect(throws: (any Error).self) { try ShellGuestReport.decode(Data("{".utf8)) }
        #expect(throws: (any Error).self) { try ShellGuestReport.decode(Data(#"{"protocol":0}"#.utf8)) }
        #expect(throws: (any Error).self) {
            try ShellGuestReport.decode(Data(#"{"protocol":1,"package":"a\nb"}"#.utf8))
        }
    }

    @Test("package versions compare numerically, then by release")
    func comparesVersions() {
        #expect(PacmanVersion.compare("0.1.0-1", "0.1.0-1") == .orderedSame)
        #expect(PacmanVersion.compare("0.1.0-1", "0.1.0-2") == .orderedAscending)
        #expect(PacmanVersion.compare("0.10.0-1", "0.9.0-1") == .orderedDescending)
        #expect(PacmanVersion.compare("1.0.0-1", "0.99.9-9") == .orderedDescending)
    }

    @Test("the status record round-trips")
    func recordRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("guest-status.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let report = try ShellGuestReport.decode(Data(#"{"protocol":1,"package":"0.1.0-1"}"#.utf8))
        try encoder.encode(ShellGuestStatusRecord(receivedAt: Date(), report: report)).write(to: url)
        #expect(ShellGuestStatusRecord.read(url)?.report == report)
    }
}

@Suite("Upstream-shell start menu row")
struct ShellGuestPresentationTests {
    private func record(_ json: String) throws -> ShellGuestStatusRecord {
        ShellGuestStatusRecord(receivedAt: Date(), report: try ShellGuestReport.decode(Data(json.utf8)))
    }

    @Test("package names yield their version")
    func packageNames() {
        #expect(ShellGuestPresentation.packageVersion(fileName: "try-omarchy-0.1.0-1-aarch64.pkg.tar.zst") == "0.1.0-1")
        #expect(ShellGuestPresentation.packageVersion(fileName: "other-0.1.0-1-aarch64.pkg.tar.zst") == nil)
    }

    @Test("a guest behind the bundled package shows the pending update")
    func pendingUpdate() throws {
        let value = ShellGuestPresentation.make(
            record: try record(#"{"protocol":1,"omarchy":"4.0.0-1","channel":"edge","package":"0.1.0-1"}"#),
            bundledPackage: "0.2.0-1")
        #expect(!value.isCurrent)
        #expect(value.lines == ["Omarchy 4.0.0-1 · edge", "Integrations 0.1.0-1 → 0.2.0-1 next launch"])
    }

    @Test("a current or newer guest is current; no report yet is neutral")
    func current() throws {
        #expect(ShellGuestPresentation.make(
            record: try record(#"{"protocol":1,"package":"0.3.0-1"}"#), bundledPackage: "0.2.0-1").isCurrent)
        #expect(ShellGuestPresentation.make(record: nil, bundledPackage: "0.2.0-1").isCurrent)
    }

    @Test("a failed install is reported")
    func failedInstall() throws {
        let value = ShellGuestPresentation.make(
            record: try record(#"{"protocol":1,"package":"0.1.0-1","install":{"requested":"x","result":"failed","message":"offline"}}"#),
            bundledPackage: "0.1.0-1")
        #expect(!value.isCurrent)
        #expect(value.lines.last == "Integration update failed: offline")
    }
}
