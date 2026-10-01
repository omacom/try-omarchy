import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("VM operation progress")
struct VMProgressTests {
    @Test("phase markers survive arbitrary pipe-read boundaries")
    func fragmentedPhases() {
        let output = "ordinary log\n[qemu-gpu] Launch phase: checking\n"
            + "[qemu-gpu] Launch phase: preparing\r\n"
            + "[qemu-gpu] Launch phase: verifying\n[qemu-gpu] Launch phase: finishing\n"
        for boundary in 0...output.utf8.count {
            let data = Data(output.utf8)
            var stream = VMProgressStream<VMLaunchPhase>(operation: .launch)
            let phases = stream.append(data.prefix(boundary)) + stream.append(data.dropFirst(boundary))
            #expect(phases == [.checking, .preparing, .verifying, .finishing])
        }
    }

    @Test("only complete exact markers change the button phase")
    func rejectsLogsAndIncompleteMarkers() {
        var stream = VMProgressStream<VMLaunchPhase>(operation: .launch)
        #expect(stream.append(Data("log [qemu-gpu] Launch phase: checking\n".utf8)).isEmpty)
        #expect(stream.append(Data("[qemu-gpu] Launch phase: unknown\n".utf8)).isEmpty)
        #expect(stream.append(Data("[qemu-gpu] Launch phase: preparing ".utf8)).isEmpty)
        #expect(stream.append(Data("\n[qemu-gpu] Launch phase: preparing".utf8)).isEmpty)
        #expect(stream.append(Data("\n".utf8)) == [.preparing])
    }

    @Test("duplicate and delayed earlier phases cannot move progress backwards")
    func phasesAdvanceOnce() {
        var stream = VMProgressStream<VMLaunchPhase>(operation: .launch)
        let output = "[qemu-gpu] Launch phase: verifying\n"
            + "[qemu-gpu] Launch phase: verifying\n[qemu-gpu] Launch phase: checking\n"
            + "[qemu-gpu] Launch phase: finishing\n"
        #expect(stream.append(Data(output.utf8)) == [.verifying, .finishing])
        var nextLaunch = VMProgressStream<VMLaunchPhase>(operation: .launch)
        #expect(nextLaunch.append(Data("[qemu-gpu] Launch phase: checking\n".utf8)) == [.checking])
    }

    @Test("large log lines are discarded without accepting their trailing marker")
    func oversizedLog() {
        var stream = VMProgressStream<VMLaunchPhase>(operation: .launch)
        let output = String(repeating: "x", count: 100_000)
            + "[qemu-gpu] Launch phase: checking\n[qemu-gpu] Launch phase: preparing\n"
        #expect(stream.append(Data(output.utf8)) == [.preparing])
    }

    @Test("the button names the work currently happening")
    func buttonFeedback() {
        #expect(VMResetPhase.checking.buttonTitle == "Checking VM…")
        #expect(VMResetPhase.deleting.buttonTitle == "Deleting VM…")
        #expect(VMLaunchPhase.preparing.buttonTitle == "Preparing image…")
        #expect(VMLaunchPhase.verifying.buttonTitle == "Verifying image…")
        #expect(VMLaunchPhase.starting.buttonTitle == "Starting Omarchy…")
        #expect(VMResetPhase.finishing.buttonTitle == "Finishing reset…")
    }

    @Test("reset and launch accept only their own phases")
    func operationIsolation() {
        var reset = VMProgressStream<VMResetPhase>(operation: .reset)
        let output = "[qemu-gpu] Launch phase: preparing\n"
            + "[qemu-gpu] Reset phase: preparing\n"
            + "[qemu-gpu] Reset phase: deleting\n[qemu-gpu] Reset phase: finishing\n"
        #expect(reset.append(Data(output.utf8)) == [.deleting, .finishing])
        var launch = VMProgressStream<VMLaunchPhase>(operation: .launch)
        #expect(launch.append(Data(output.utf8)) == [.preparing])
    }
}
