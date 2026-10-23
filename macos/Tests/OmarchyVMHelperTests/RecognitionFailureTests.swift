import Foundation
import Testing

@testable import OmarchyVMHelper

struct RecognitionFailureTests {
    private struct Stopped: LocalizedError {
        var errorDescription: String? { "recogniser stopped" }
    }

    @Test func aFailureIsReportedWithoutWaitingForTheStop() async {
        let failing = Task<String, Error> { throw Stopped() }
        let message = await withCheckedContinuation { continuation in
            RecognitionFailure.watch(failing) { continuation.resume(returning: $0) }
        }
        #expect(message == "recogniser stopped")
    }

    @Test func aRecognitionThatFinishesReportsNothing() async throws {
        let finished = Task<String, Error> { "hello" }
        await confirmation(expectedCount: 0) { reported in
            RecognitionFailure.watch(finished) { _ in reported() }
            _ = try? await finished.value
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
