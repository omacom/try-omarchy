import Testing
@testable import OmarchyVMHelper

@Suite("Networking helper repair")
@MainActor
struct NetworkServiceTests {
    enum Failure: Error { case disconnected, denied }

    @Test("Repeated repair preserves a working registered helper")
    func healthyRepair() async throws {
        var checks = 0
        for _ in 0..<3 {
            try await NetworkService.repair(isEnabled: true,
                prepare: { Issue.record("A healthy helper must not be registered again") },
                verify: { checks += 1 },
                remove: { Issue.record("A healthy helper must not be removed") })
        }
        #expect(checks == 3)
    }

    @Test("First setup does not unregister an absent helper")
    func firstSetup() async throws {
        var registered = false
        try await NetworkService.repair(isEnabled: false,
            prepare: { registered = true },
            verify: { #expect(registered) },
            remove: { Issue.record("An absent helper must not be removed") })
        #expect(registered)
    }

    @Test("An approved but disconnected helper still takes the recovery path")
    func disconnectedRepair() async throws {
        var events: [String] = []
        try await NetworkService.repair(isEnabled: true,
            prepare: { events.append("register") },
            verify: {
                events.append("check")
                if events.count == 1 { throw Failure.disconnected }
            },
            remove: { events.append("remove") })
        #expect(events == ["check", "remove", "register", "check"])
    }

    @Test("Registration denial is reported without claiming a verified connection")
    func registrationFailure() async {
        await #expect(throws: Failure.denied) {
            try await NetworkService.repair(isEnabled: false,
                prepare: { throw Failure.denied },
                verify: { Issue.record("Denied registration must not report success") },
                remove: { Issue.record("An absent helper must not be removed") })
        }
    }
}
