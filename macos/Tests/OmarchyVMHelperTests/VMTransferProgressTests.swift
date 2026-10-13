import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("VM transfer progress")
struct VMTransferProgressTests {
    @Test("Fragmented UTF-8 and progress records preserve updates and separate actual errors")
    func fragmentedOutput() {
        let expected = VMTransferProgress(phase: .verifying, completedBytes: 40, totalBytes: 100)
        let bytes = Data((VMTransferProgress(phase: .checking).line + expected.line + "Copy failed: 日本語\n").utf8)
        var reader = VMTransferOutput()
        var updates: [VMTransferProgress] = []
        for byte in bytes { updates += reader.append(Data([byte])) }
        updates += reader.append(Data(), finished: true)
        #expect(updates == [VMTransferProgress(phase: .checking), expected])
        #expect(reader.errorMessage == "Copy failed: 日本語")
    }

    @Test("Incomplete and malformed progress cannot replace errors or grow buffers indefinitely")
    func malformedOutput() {
        var reader = VMTransferOutput()
        #expect(reader.append(Data((VMTransferProgress.prefix + "bad\n").utf8)).isEmpty)
        #expect(reader.append(Data(VMTransferProgress(phase: .verifying, completedBytes: -1, totalBytes: 5).line.utf8)).isEmpty)
        _ = reader.append(Data(repeating: 65, count: 100_000))
        #expect(reader.errorMessage.utf8.count <= 8192)
        _ = reader.append(Data("\nReal failure".utf8), finished: true)
        #expect(reader.errorMessage.hasSuffix("Real failure"))
    }

    @Test("A progress record reaches the UI reader before a child waiting for acknowledgment exits")
    func livePipe() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "printf '%s' \"$1\"; read -r acknowledgment", "vm-progress-test", VMTransferProgress(phase: .checking).line]
        let output = Pipe()
        let acknowledgment = Pipe()
        child.standardOutput = output
        child.standardInput = acknowledgment
        try child.run()
        let timeout = DispatchWorkItem { if child.isRunning { child.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeout)
        defer { timeout.cancel(); if child.isRunning { child.terminate() }; child.waitUntilExit() }
        var receivedWhileRunning = false
        let errors = try VMTransferOutput.read(from: output.fileHandleForReading) { update in
            receivedWhileRunning = child.isRunning && update.phase == .checking
            if child.isRunning { acknowledgment.fileHandleForWriting.write(Data("received\n".utf8)) }
        }
        #expect(receivedWhileRunning)
        #expect(errors.isEmpty)
    }

    @Test("Only measured verification reports a percentage")
    func percentages() {
        #expect(VMTransferProgress(phase: .copying).fraction == nil)
        #expect(VMTransferProgress(phase: .checking).fraction == nil)
        #expect(VMTransferProgress(phase: .finishing).fraction == nil)
        #expect(VMTransferProgress(phase: .verifying, completedBytes: 50, totalBytes: 100).fraction == 0.5)
    }
}
