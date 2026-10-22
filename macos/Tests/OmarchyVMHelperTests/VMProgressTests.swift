import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("VM operation progress")
struct VMProgressTests {
    @Test("phase markers survive arbitrary pipe-read boundaries")
    func fragmentedPhases() {
        let output = "ordinary log\n[qemu-gpu] Launch phase: checking\n"
            + "[qemu-gpu] Launch phase: preparing\r\n"
            + "[qemu-gpu] Launch phase: finishing\n"
        for boundary in 0...output.utf8.count {
            let data = Data(output.utf8)
            var stream = VMProgressStream<VMLaunchPhase>(operation: .launch)
            let updates = stream.append(data.prefix(boundary)) + stream.append(data.dropFirst(boundary))
            #expect(updates.map(\.phase) == [.checking, .preparing, .finishing])
        }
    }

    @Test("only complete exact markers change the button phase")
    func rejectsLogsAndIncompleteMarkers() {
        var stream = VMProgressStream<VMLaunchPhase>(operation: .launch)
        #expect(stream.append(Data("log [qemu-gpu] Launch phase: checking\n".utf8)).isEmpty)
        #expect(stream.append(Data("[qemu-gpu] Launch phase: unknown\n".utf8)).isEmpty)
        #expect(stream.append(Data("[qemu-gpu] Launch phase: preparing ".utf8)).isEmpty)
        #expect(stream.append(Data("\n[qemu-gpu] Launch phase: preparing".utf8)).isEmpty)
        #expect(stream.append(Data("\n".utf8)) == [VMProgress(phase: .preparing)])
    }

    @Test("duplicate and delayed earlier phases cannot move progress backwards")
    func phasesAdvanceOnce() {
        var stream = VMProgressStream<VMLaunchPhase>(operation: .launch)
        let output = "[qemu-gpu] Launch phase: preparing\n"
            + "[qemu-gpu] Launch phase: preparing\n[qemu-gpu] Launch phase: checking\n"
            + "[qemu-gpu] Launch phase: finishing\n"
        #expect(stream.append(Data(output.utf8)).map(\.phase) == [.preparing, .finishing])
        var nextLaunch = VMProgressStream<VMLaunchPhase>(operation: .launch)
        #expect(nextLaunch.append(Data("[qemu-gpu] Launch phase: checking\n".utf8)).map(\.phase) == [.checking])
    }

    @Test("large log lines are discarded without accepting their trailing marker")
    func oversizedLog() {
        var stream = VMProgressStream<VMLaunchPhase>(operation: .launch)
        let output = String(repeating: "x", count: 100_000)
            + "[qemu-gpu] Launch phase: checking\n[qemu-gpu] Launch phase: preparing\n"
        #expect(stream.append(Data(output.utf8)).map(\.phase) == [.preparing])
    }

    @Test("a percentage belongs to its phase and only rises")
    func percentages() {
        var stream = VMProgressStream<VMLaunchPhase>(operation: .launch)
        #expect(stream.append(Data("[qemu-gpu] Launch progress: 10\n".utf8)).isEmpty)
        let output = "[qemu-gpu] Launch phase: preparing\n"
            + "[qemu-gpu] Launch progress: 0\n[qemu-gpu] Launch progress: 42\n"
            + "[qemu-gpu] Launch progress: 42\n[qemu-gpu] Launch progress: 7\n"
            + "[qemu-gpu] Launch progress: 101\n[qemu-gpu] Launch progress: +50\n"
            + "[qemu-gpu] Launch progress: 50 \n[qemu-gpu] Launch progress: 0050\n"
            + "[qemu-gpu] Launch phase: finishing\n[qemu-gpu] Launch progress: 5\n"
        #expect(stream.append(Data(output.utf8)) == [
            VMProgress(phase: .preparing),
            VMProgress(phase: .preparing, percent: 0),
            VMProgress(phase: .preparing, percent: 42),
            VMProgress(phase: .finishing),
            VMProgress(phase: .finishing, percent: 5),
        ])
    }

    @Test("the button names the work currently happening")
    func buttonFeedback() {
        #expect(VMResetPhase.checking.buttonTitle == "Checking VM")
        #expect(VMResetPhase.deleting.buttonTitle == "Deleting VM")
        #expect(VMLaunchPhase.verifying.buttonTitle == "Verifying the Omarchy image")
        #expect(VMLaunchPhase.preparing.buttonTitle == "Unpacking Omarchy")
        #expect(VMLaunchPhase.finishing.buttonTitle == "Compacting the disk")
        #expect(VMLaunchPhase.starting.buttonTitle == "Starting Omarchy")
        #expect(VMResetPhase.finishing.buttonTitle == "Finishing reset")
        #expect(VMProgress(phase: VMLaunchPhase.preparing, percent: 42).title == "Unpacking Omarchy (42%)")
    }

    @Test("reset and launch accept only their own phases")
    func operationIsolation() {
        var reset = VMProgressStream<VMResetPhase>(operation: .reset)
        let output = "[qemu-gpu] Launch phase: preparing\n"
            + "[qemu-gpu] Reset phase: preparing\n"
            + "[qemu-gpu] Reset phase: deleting\n[qemu-gpu] Reset phase: finishing\n"
        #expect(reset.append(Data(output.utf8)).map(\.phase) == [.deleting, .finishing])
        var launch = VMProgressStream<VMLaunchPhase>(operation: .launch)
        #expect(launch.append(Data(output.utf8)).map(\.phase) == [.preparing])
    }
}
