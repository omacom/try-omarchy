import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("VM resource settings")
struct VMResourcePreferencesTests {
    private func limits(cpus: Int = 18, memoryGiB: UInt64 = 48) -> VMResourceLimits {
        VMResourceLimits(hostCPUCount: cpus, hostMemoryBytes: memoryGiB << 30)
    }

    @Test("An unchanged install keeps eight cores and four GiB, capped by host CPUs")
    func defaults() {
        #expect(limits().resolve(nil) == VMResources(cpuCount: 8, memoryGiB: 4))
        #expect(limits(cpus: 6, memoryGiB: 8).defaults == VMResources(cpuCount: 6, memoryGiB: 4))
        #expect(limits(memoryGiB: 7).memoryChoicesGiB.contains(4))
    }

    @Test("All host cores and twelve GiB are selectable")
    func allCores() throws {
        let resources = try limits().validate(cpuCount: "18", memoryGiB: "12")
        #expect(resources == VMResources(cpuCount: 18, memoryGiB: 12))
        #expect(StartMenuPresentation.resources(resources) == "18 processor cores · 12 GiB memory")
    }

    @Test("Both resource limits accept their boundaries")
    func boundaries() throws {
        #expect(try limits().validate(cpuCount: "4", memoryGiB: "4")
            == VMResources(cpuCount: 4, memoryGiB: 4))
        #expect(try limits().validate(cpuCount: "18", memoryGiB: "16")
            == VMResources(cpuCount: 18, memoryGiB: 16))
        #expect(limits(memoryGiB: 16).memoryChoicesGiB == [4, 6, 8])
        #expect(limits(memoryGiB: 8).memoryChoicesGiB == [4])
        #expect(throws: VMResourceInputError.self) {
            try limits().validate(cpuCount: "19", memoryGiB: "12")
        }
        #expect(throws: VMResourceInputError.self) {
            try limits().validate(cpuCount: "18", memoryGiB: "45")
        }
    }

    @Test("Malformed edits cannot be saved", arguments: ["", "0", "-1", "1.5", "abc", "1+2", "18446744073709551620"])
    func malformedInputs(value: String) {
        #expect(throws: VMResourceInputError.self) {
            try limits().validate(cpuCount: value, memoryGiB: "12")
        }
        #expect(throws: VMResourceInputError.self) {
            try limits().validate(cpuCount: "18", memoryGiB: value)
        }
    }

    @Test("Moving to a smaller Mac resolves each saved value independently")
    func smallerHost() {
        let small = limits(cpus: 8, memoryGiB: 16)
        #expect(small.resolve(VMResources(cpuCount: 18, memoryGiB: 12))
            == VMResources(cpuCount: 8, memoryGiB: 4))
        #expect(small.resolve(VMResources(cpuCount: 6, memoryGiB: 44))
            == VMResources(cpuCount: 6, memoryGiB: 4))
        #expect(small.resolve(VMResources(cpuCount: -1, memoryGiB: Int.max)) == small.defaults)
    }

    @Test("Saved choices survive reopening and resolution does not rewrite them")
    func persistence() {
        let fixture = DefaultsFixture()
        #expect(fixture.store.load() == nil)
        let choice = VMResources(cpuCount: 18, memoryGiB: 12)
        fixture.store.save(choice)
        let reopened = VMResourcePreferenceStore(defaults: fixture.defaults)
        #expect(reopened.load() == choice)
        #expect(limits(cpus: 8, memoryGiB: 8).resolve(reopened.load())
            == VMResources(cpuCount: 8, memoryGiB: 4))
        #expect(reopened.load() == choice)
    }

    @Test("Corrupt and future saved settings fall back to the defaults")
    func corruptPreferences() throws {
        let fixture = DefaultsFixture()
        for data in [
            Data("invalid".utf8),
            try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 2,
                "resources": ["cpuCount": 18, "memoryGiB": 12],
            ]),
        ] {
            fixture.defaults.set(data, forKey: VMResourcePreferenceStore.key)
            #expect(fixture.store.load() == nil)
            #expect(limits().resolve(fixture.store.load()) == limits().defaults)
        }
    }

    @Test("The launch uses the displayed selection instead of inherited resource overrides")
    func launchEnvironment() {
        let environment = VMResourceLaunchConfiguration.make(
            baseEnvironment: [
                "KEEP_ME": "yes",
                VMResourceLaunchConfiguration.cpuEnvironmentKey: "999",
                VMResourceLaunchConfiguration.memoryEnvironmentKey: "invalid",
            ],
            preferences: VMResources(cpuCount: 18, memoryGiB: 12),
            limits: limits()
        ).environment
        #expect(environment == [
            "KEEP_ME": "yes",
            "OMARCHY_QEMU_GPU_CPUS": "18",
            "OMARCHY_QEMU_GPU_MEMORY_MIB": "12288",
        ])
        let resolved = VMResourceLaunchConfiguration.make(
            baseEnvironment: [:],
            preferences: VMResources(cpuCount: 18, memoryGiB: 12),
            limits: limits(cpus: 8, memoryGiB: 8)
        ).environment
        #expect(resolved[VMResourceLaunchConfiguration.cpuEnvironmentKey] == "8")
        #expect(resolved[VMResourceLaunchConfiguration.memoryEnvironmentKey] == "4096")
    }

    @Test("Existing memory choices survive upgrading to Resources without rewriting preferences")
    func adoptsExistingMemory() {
        let fixture = DefaultsFixture()
        let memoryStore = MemoryPreferenceStore(defaults: fixture.defaults)
        memoryStore.save(MemoryPreferences(memoryMiB: 12288))
        #expect(fixture.store.load() == VMResources(cpuCount: 8, memoryGiB: 12))
        #expect(limits(cpus: 6, memoryGiB: 8).resolve(fixture.store.load())
            == VMResources(cpuCount: 6, memoryGiB: 4))
        #expect(memoryStore.load().memoryMiB == 12288)
        #expect(fixture.defaults.object(forKey: VMResourcePreferenceStore.key) == nil)
        fixture.store.save(VMResources(cpuCount: 18, memoryGiB: 8))
        #expect(fixture.store.load() == VMResources(cpuCount: 18, memoryGiB: 8))
    }

    @Test("Resources uses the existing memory menu and its host headroom")
    func memoryPolicyAgreement() {
        for hostGiB: UInt64 in [8, 16, 24, 48, 128] {
            #expect(limits(memoryGiB: hostGiB).memoryChoicesGiB.map { $0 * 1024 }
                == MemoryPolicy.allowedChoicesMiB(hostMemoryMiB: Int(hostGiB) * 1024))
        }
    }

    private final class DefaultsFixture {
        let suiteName = "VMResourcePreferencesTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let store: VMResourcePreferenceStore

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            store = VMResourcePreferenceStore(defaults: defaults)
        }

        deinit { defaults.removePersistentDomain(forName: suiteName) }
    }
}
