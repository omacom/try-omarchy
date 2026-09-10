import Darwin
import Foundation
import Testing
@testable import OmarchyVMHelper

struct SettingsLifecycleTests {
    @Test func quitAndSignalsOverrideSettingsActions() {
        var lifecycle = VMRunLifecycle()
        lifecycle.requestSettingsAction(.restart)
        #expect(lifecycle.settingsAction == .restart)
        #expect(lifecycle.isStopping)
        #expect(!lifecycle.isTerminating)
        lifecycle.requestQuit()
        #expect(lifecycle.isTerminating)
        #expect(lifecycle.settingsAction == nil)
        lifecycle.requestSettingsAction(.restart)
        #expect(lifecycle.settingsAction == nil)
        lifecycle.childExited()
        #expect(!lifecycle.isStopping)
        lifecycle.requestSettingsAction(.manage)
        lifecycle.requestTermination(signal: SIGTERM)
        lifecycle.cancelSettingsAction()
        #expect(lifecycle.isStopping)
        #expect(lifecycle.settingsAction == nil)
    }

    @Test func failedPowerdownCanBeRetried() {
        var lifecycle = VMRunLifecycle()
        lifecycle.requestSettingsAction(.restart)
        lifecycle.cancelSettingsAction()
        #expect(!lifecycle.isStopping)
        lifecycle.requestSettingsAction(.manage)
        #expect(lifecycle.settingsAction == .manage)
        lifecycle.childExited()
        #expect(lifecycle.settingsAction == nil)
    }

    @Test func disposableDiskSurvivesRelaunchAndIsRemovedAtSessionEnd() throws {
        let workspace = DisposableVMWorkspace()
        defer { workspace.remove() }
        let first = try workspace.prepare()
        let disk = first.appendingPathComponent("rootfs.ext4")
        try Data("saved work".utf8).write(to: disk)
        #expect(try workspace.prepare() == first)
        #expect(try Data(contentsOf: disk) == Data("saved work".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: first.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        workspace.remove()
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(try workspace.prepare() != first)
    }
}
