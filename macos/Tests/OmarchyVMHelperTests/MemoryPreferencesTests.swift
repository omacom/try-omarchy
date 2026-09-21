import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Memory policy")
struct MemoryPolicyTests {
    @Test("An 8 GiB host offers only the default")
    func eightGiBHostOffersOnlyDefault() {
        #expect(MemoryPolicy.allowedChoicesMiB(hostMemoryMiB: 8192) == [4096])
    }

    @Test("A 16 GiB host offers up to 12 GiB")
    func sixteenGiBHostOffersUpToTwelve() {
        #expect(
            MemoryPolicy.allowedChoicesMiB(hostMemoryMiB: 16384) == [4096, 6144, 8192, 12288]
        )
    }

    @Test("Memory choices grow with host capacity")
    func choicesGrowWithHost() {
        #expect(
            MemoryPolicy.allowedChoicesMiB(hostMemoryMiB: 24576)
                == [4096, 6144, 8192, 12288, 16384, 20480]
        )
        #expect(MemoryPolicy.allowedChoicesMiB(hostMemoryMiB: 49152).last == 45056)
        #expect(MemoryPolicy.allowedChoicesMiB(hostMemoryMiB: 131072).last == 126976)
    }

    @Test("Every non-default choice leaves the host its headroom")
    func choicesLeaveHeadroom() {
        for host in [8192, 12288, 16384, 24576, 32768, 65536] {
            for choice in MemoryPolicy.allowedChoicesMiB(hostMemoryMiB: host)
            where choice != MemoryPolicy.defaultMemoryMiB {
                #expect(choice + MemoryPolicy.hostHeadroomMiB <= host)
            }
        }
    }

    @Test("A stored choice that fits this host is kept")
    func resolutionKeepsAFittingChoice() {
        #expect(
            MemoryPolicy.resolvedMemoryMiB(preferredMiB: 6144, hostMemoryMiB: 16384)
                == 6144
        )
    }

    @Test("A stored choice that no longer fits falls back to the default")
    func resolutionFallsBackWhenChoiceNoLongerFits() {
        #expect(
            MemoryPolicy.resolvedMemoryMiB(preferredMiB: 8192, hostMemoryMiB: 8192)
                == MemoryPolicy.defaultMemoryMiB
        )
    }

    @Test("A value that was never a listed choice falls back to the default")
    func resolutionFallsBackForUnlistedValue() {
        #expect(
            MemoryPolicy.resolvedMemoryMiB(preferredMiB: 5000, hostMemoryMiB: 65536)
                == 8192
        )
    }

    @Test("Defaults change at 16 GiB without replacing an explicit 4 GiB choice")
    func hostAwareDefaults() {
        #expect(MemoryPolicy.recommendedMemoryMiB(hostMemoryMiB: 16383) == 4096)
        #expect(MemoryPolicy.recommendedMemoryMiB(hostMemoryMiB: 16384) == 8192)
        #expect(MemoryPolicy.recommendedMemoryMiB(hostMemoryMiB: 49152) == 8192)
        #expect(MemoryPolicy.resolvedMemoryMiB(preferredMiB: 4096, hostMemoryMiB: 16384) == 4096)
    }

    @Test("Higher allocations show an advisory when macOS has less than 8 GiB left")
    func performanceAdvisory() {
        #expect(MemoryPolicy.choiceTitle(memoryMiB: 8192, hostMemoryMiB: 16384) == "8 GiB · default")
        #expect(MemoryPolicy.choiceTitle(memoryMiB: 12288, hostMemoryMiB: 16384) == "12 GiB · may slow macOS")
        #expect(!MemoryPolicy.maySlowHost(memoryMiB: 40960, hostMemoryMiB: 49152))
        #expect(MemoryPolicy.maySlowHost(memoryMiB: 45056, hostMemoryMiB: 49152))
    }

    @Test("Labels show whole GiB when exact, MiB otherwise")
    func displayLabels() {
        #expect(MemoryPolicy.displayLabel(memoryMiB: 6144) == "6 GiB")
        #expect(MemoryPolicy.displayLabel(memoryMiB: 3000) == "3000 MiB")
    }
}

@Suite("Memory preferences")
struct MemoryPreferenceStoreTests {
    @Test("Legacy preferences retain their original baseline for migration")
    func defaultsToRecommendedMemory() {
        let fixture = DefaultsFixture()

        #expect(fixture.store.load() == .defaults)
        #expect(fixture.store.load().memoryMiB == MemoryPolicy.defaultMemoryMiB)
    }

    @Test("A memory choice persists")
    func savesChoice() {
        let fixture = DefaultsFixture()
        fixture.store.save(MemoryPreferences(memoryMiB: 8192))

        let reopened = MemoryPreferenceStore(defaults: fixture.defaults)
        #expect(reopened.load() == MemoryPreferences(memoryMiB: 8192))
    }

    @Test("Invalid or future preferences fail safely")
    func invalidPreferencesUseDefault() throws {
        let fixture = DefaultsFixture()
        fixture.defaults.set(Data("junk".utf8), forKey: MemoryPreferenceStore.key)
        #expect(fixture.store.load() == .defaults)

        let future = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": MemoryPreferenceStore.schemaVersion + 1,
            "memoryMiB": 8192,
        ])
        fixture.defaults.set(future, forKey: MemoryPreferenceStore.key)
        #expect(fixture.store.load() == .defaults)
    }

    private final class DefaultsFixture {
        let suiteName = "MemoryPreferenceStoreTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let store: MemoryPreferenceStore

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            store = MemoryPreferenceStore(defaults: defaults)
        }

        deinit {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

@Suite("Memory launch configuration")
struct MemoryLaunchConfigurationTests {
    @Test("Publishes the resolved choice and replaces inherited values")
    func publishesChoice() {
        let inherited = [
            "KEEP_ME": "yes",
            MemoryPolicy.environmentKey: "99999",
        ]

        let chosen = MemoryLaunchConfiguration.make(
            baseEnvironment: inherited,
            preferences: MemoryPreferences(memoryMiB: 6144),
            hostMemoryMiB: 16384
        )
        #expect(chosen.environment["KEEP_ME"] == "yes")
        #expect(chosen.environment[MemoryPolicy.environmentKey] == "6144")
    }

    @Test("Never exports a choice this host cannot hold")
    func neverExportsAnOversizedChoice() {
        let configuration = MemoryLaunchConfiguration.make(
            baseEnvironment: [:],
            preferences: MemoryPreferences(memoryMiB: 16384),
            hostMemoryMiB: 8192
        )
        #expect(configuration.environment[MemoryPolicy.environmentKey] == "4096")
    }
}

@Suite("Memory start menu presentation")
struct StartMenuMemoryPresentationTests {
    @Test("Marks the default entry and selects the stored choice")
    func marksDefaultAndSelectsChoice() {
        let presentation = StartMenuPresentation.memory(
            preferredMiB: 8192,
            hostMemoryMiB: 16384
        )
        #expect(presentation.choiceTitles == ["4 GiB", "6 GiB", "8 GiB · default", "12 GiB · may slow macOS"])
        #expect(presentation.choicesMiB == [4096, 6144, 8192, 12288])
        #expect(presentation.selectedIndex == 2)
        #expect(presentation.isAdjustable)
    }

    @Test("An 8 GiB host renders the row as informational")
    func eightGiBHostIsNotAdjustable() {
        let presentation = StartMenuPresentation.memory(
            preferredMiB: 4096,
            hostMemoryMiB: 8192
        )
        #expect(presentation.choicesMiB == [4096])
        #expect(presentation.selectedIndex == 0)
        #expect(!presentation.isAdjustable)
        #expect(presentation.detail.contains("4 GiB"))
    }

    @Test("A stored choice that no longer fits presents as the default")
    func staleChoicePresentsAsDefault() {
        let presentation = StartMenuPresentation.memory(
            preferredMiB: 16384,
            hostMemoryMiB: 16384
        )
        #expect(
            presentation.choicesMiB[presentation.selectedIndex]
                == 8192
        )
    }
}

/// The memory contract is split across two languages: the app resolves and
/// exports the value, the launcher re-validates it. Pin the shared constants
/// to the shell source so neither side can drift silently; the launcher's
/// semantics are exercised by qemu-memory-contract.test.sh.
@Suite("Memory cross-language contract")
struct MemoryShellContractTests {
    @Test("the launcher uses the same key, default, and minimum")
    func launcherAgreesOnConstants() throws {
        let launcher = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("run-qemu-gpu.sh")
        let source = try String(contentsOf: launcher, encoding: .utf8)

        #expect(source.contains(
            "${\(MemoryPolicy.environmentKey):-$default_memory_mib}"
        ))
        #expect(source.contains("default_memory_mib=4096"))
        #expect(source.contains("host_memory_mib >= 16384"))
        #expect(source.contains("default_memory_mib=8192"))
        #expect(source.contains("memory_mib + \(MemoryPolicy.hostHeadroomMiB) <= host_memory_mib"))
        #expect(source.contains(
            "memory_mib >= \(MemoryPolicy.minimumMemoryMiB)"
        ))
    }
}
