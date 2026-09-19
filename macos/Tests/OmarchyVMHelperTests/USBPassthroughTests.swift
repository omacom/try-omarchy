import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("USB passthrough")
struct USBPassthroughTests {
    private let iPhone = USBDeviceIdentity(vendorId: 0x05AC, productId: 0x12A8, name: "iPhone")
    private let drive = USBDeviceIdentity(vendorId: 0x05E3, productId: 0x0764, name: "USB Storage")

    @Test("the launcher receives the vendor/product pair the launcher script accepts")
    func publishesTheChosenDevice() {
        let configuration = USBPassthroughLaunchConfiguration.make(
            baseEnvironment: [:],
            preference: USBDevicePreference(device: iPhone, isEnabled: true)
        )
        #expect(configuration.device == iPhone)
        #expect(
            configuration.environment[USBPassthroughPolicy.environmentKey]
                == "vendorid=0x05ac,productid=0x12a8"
        )
    }

    @Test("a device that is saved but switched off never reaches QEMU")
    func disabledPassthroughRemovesTheKey() {
        let configuration = USBPassthroughLaunchConfiguration.make(
            baseEnvironment: [:],
            preference: USBDevicePreference(device: iPhone, isEnabled: false)
        )
        #expect(configuration.device == nil)
        #expect(configuration.environment[USBPassthroughPolicy.environmentKey] == nil)
    }

    @Test("an inherited value is cleared rather than silently reused as a choice")
    func staleEnvironmentIsCleared() {
        // Only a value the user did not pick in this app is at stake: an empty
        // string is an environment leak, not a deliberate override.
        let configuration = USBPassthroughLaunchConfiguration.make(
            baseEnvironment: [USBPassthroughPolicy.environmentKey: ""],
            preference: .disabled
        )
        #expect(configuration.environment[USBPassthroughPolicy.environmentKey] == nil)
    }

    @Test("an explicit environment override wins over the saved choice")
    func environmentOverrideWins() {
        let configuration = USBPassthroughLaunchConfiguration.make(
            baseEnvironment: [USBPassthroughPolicy.environmentKey: "hostbus=1,hostaddr=6"],
            preference: USBDevicePreference(device: iPhone, isEnabled: true)
        )
        #expect(
            configuration.environment[USBPassthroughPolicy.environmentKey] == "hostbus=1,hostaddr=6"
        )
    }

    @Test("the row explains whether the chosen device is plugged in")
    func menuStateTracksConnection() {
        let preference = USBDevicePreference(device: iPhone, isEnabled: true)
        let attached = USBDeviceMenuState.make(
            preference: preference,
            connected: [drive, iPhone],
            environment: [:]
        )
        #expect(attached.isConnected)
        #expect(StartMenuPresentation.usbDevice(state: attached).isGranted)

        let detached = USBDeviceMenuState.make(
            preference: preference,
            connected: [drive],
            environment: [:]
        )
        #expect(!detached.isConnected)
        let presentation = StartMenuPresentation.usbDevice(state: detached)
        #expect(!presentation.isGranted)
        #expect(presentation.detail.contains("not plugged in"))
        #expect(presentation.toggleActionTitle == "Turn Off")
    }

    @Test("the row offers no switch until a device has been chosen")
    func noDeviceOffersNoToggle() {
        let presentation = StartMenuPresentation.usbDevice(state: .disabled)
        #expect(!presentation.isGranted)
        #expect(presentation.toggleActionTitle == nil)
        #expect(presentation.actionsEnabled)
    }

    @Test("an environment override disables the buttons that would not change it")
    func overrideLocksTheRow() {
        let state = USBDeviceMenuState.make(
            preference: .disabled,
            connected: [],
            environment: [USBPassthroughPolicy.environmentKey: "vendorid=0x05ac"]
        )
        let presentation = StartMenuPresentation.usbDevice(state: state)
        #expect(!presentation.actionsEnabled)
        #expect(presentation.isGranted)
        #expect(presentation.detail.contains(USBPassthroughPolicy.environmentKey))
    }

    @Test("a stored device survives a round trip and an invalid one is dropped")
    func storeRejectsOutOfRangeIdentifiers() throws {
        let suite = "omarchy-usb-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = USBDevicePreferenceStore(defaults: defaults)

        store.save(USBDevicePreference(device: iPhone, isEnabled: true))
        #expect(store.load() == USBDevicePreference(device: iPhone, isEnabled: true))

        store.save(USBDevicePreference(
            device: USBDeviceIdentity(vendorId: 0x1_0000, productId: 1, name: "Bogus"),
            isEnabled: true
        ))
        #expect(store.load() == .disabled)
    }

    @Test("a device with no product string still reads as a device")
    func namelessDeviceFallsBackToIdentifiers() {
        let anonymous = USBDeviceIdentity(vendorId: 0x0451, productId: 0x8142, name: "")
        #expect(anonymous.displayName == "0451:8142")
        #expect(iPhone.displayName == "iPhone · 05ac:12a8")
    }

    @Test("a storage reset never claims a device away from macOS")
    func resetDropsThePassthroughKey() {
        let sanitized = QEMUGPURuntimeEnvironment.sanitizedForReset(
            [USBPassthroughPolicy.environmentKey: "vendorid=0x05ac"]
        )
        #expect(sanitized[USBPassthroughPolicy.environmentKey] == nil)
    }
}
