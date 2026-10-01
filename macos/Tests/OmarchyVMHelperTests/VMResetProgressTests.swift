import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("VM reset progress")
struct VMResetProgressTests {
    @Test("phase markers survive arbitrary pipe-read boundaries")
    func fragmentedPhases() {
        let output = "ordinary log\n[qemu-gpu] Reset phase: deleting\n"
            + "[qemu-gpu] Reset phase: preparing\r\n"
            + "[qemu-gpu] Reset phase: verifying\n[qemu-gpu] Reset phase: finishing\n"
        for boundary in 0...output.utf8.count {
            let data = Data(output.utf8)
            var stream = VMResetProgressStream()
            let phases = stream.append(data.prefix(boundary)) + stream.append(data.dropFirst(boundary))
            #expect(phases == [.deleting, .preparing, .verifying, .finishing])
        }
    }

    @Test("only complete exact markers change the button phase")
    func rejectsLogsAndIncompleteMarkers() {
        var stream = VMResetProgressStream()
        #expect(stream.append(Data("log [qemu-gpu] Reset phase: deleting\n".utf8)).isEmpty)
        #expect(stream.append(Data("[qemu-gpu] Reset phase: unknown\n".utf8)).isEmpty)
        #expect(stream.append(Data("[qemu-gpu] Reset phase: preparing ".utf8)).isEmpty)
        #expect(stream.append(Data("\n[qemu-gpu] Reset phase: preparing".utf8)).isEmpty)
        #expect(stream.append(Data("\n".utf8)) == [.preparing])
    }

    @Test("duplicate and delayed earlier phases cannot move progress backwards")
    func phasesAdvanceOnce() {
        var stream = VMResetProgressStream()
        let output = "[qemu-gpu] Reset phase: verifying\n"
            + "[qemu-gpu] Reset phase: verifying\n[qemu-gpu] Reset phase: deleting\n"
            + "[qemu-gpu] Reset phase: finishing\n"
        #expect(stream.append(Data(output.utf8)) == [.verifying, .finishing])
        var nextReset = VMResetProgressStream()
        #expect(nextReset.append(Data("[qemu-gpu] Reset phase: deleting\n".utf8)) == [.deleting])
    }

    @Test("large log lines are discarded without accepting their trailing marker")
    func oversizedLog() {
        var stream = VMResetProgressStream()
        let output = String(repeating: "x", count: 100_000)
            + "[qemu-gpu] Reset phase: deleting\n[qemu-gpu] Reset phase: preparing\n"
        #expect(stream.append(Data(output.utf8)) == [.preparing])
    }

    @Test("the button names the work currently happening")
    func buttonFeedback() {
        #expect(VMResetPhase.checking.buttonTitle == "Checking VM…")
        #expect(VMResetPhase.deleting.buttonTitle == "Deleting VM…")
        #expect(VMResetPhase.preparing.buttonTitle == "Preparing image…")
        #expect(VMResetPhase.verifying.buttonTitle == "Verifying image…")
        #expect(VMResetPhase.finishing.buttonTitle == "Finishing reset…")
    }
}
