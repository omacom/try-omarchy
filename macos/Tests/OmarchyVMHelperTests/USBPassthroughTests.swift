import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("USB passthrough")
struct USBPassthroughTests {
    private let iPhone = USBDeviceIdentity(vendorId: 0x05AC, productId: 0x12A8, name: "iPhone")
    private let drive = USBDeviceIdentity(vendorId: 0x05E3, productId: 0x0764, name: "USB Storage")

    @Test("the launcher script receives the vendor/product pair it validates")
    func publishesTheChosenDevice() {
        let configuration = USBPassthroughLaunchConfiguration.make(
            baseEnvironment: [:],
            preference: USBDevicePreference(device: iPhone, isEnabled: true),
            connected: [iPhone]
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
            preference: USBDevicePreference(device: iPhone, isEnabled: false),
            connected: [iPhone]
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
            preference: .disabled,
            connected: []
        )
        #expect(configuration.environment[USBPassthroughPolicy.environmentKey] == nil)
    }

    @Test("an explicit environment override wins over the saved choice")
    func environmentOverrideWins() {
        let configuration = USBPassthroughLaunchConfiguration.make(
            baseEnvironment: [USBPassthroughPolicy.environmentKey: "hostbus=1,hostaddr=6"],
            preference: USBDevicePreference(device: iPhone, isEnabled: true),
            connected: [iPhone]
        )
        #expect(
            configuration.environment[USBPassthroughPolicy.environmentKey] == "hostbus=1,hostaddr=6"
        )
    }

    @Test("the port is read from locationID the way libusb numbers it")
    func locationIdDecodesToHostBusAndPort() {
        let direct = USBDeviceIdentity(vendorId: 1, productId: 2, name: "", locationId: 0x0010_0000)
        #expect(direct.hostBus == 0)
        #expect(direct.hostPort == "1")
        let behindHub = USBDeviceIdentity(vendorId: 1, productId: 2, name: "", locationId: 0x0223_0000)
        #expect(behindHub.hostBus == 2)
        #expect(behindHub.hostPort == "2.3")
    }

    @Test("a lone device follows its vendor/product pair from port to port")
    func loneDeviceIsNotPinned() {
        var moved = drive
        moved.locationId = 0x0130_0000
        var saved = drive
        saved.locationId = 0x0110_0000
        #expect(
            USBPassthroughPolicy.properties(for: saved, connected: [moved])
                == "vendorid=0x05e3,productid=0x0764"
        )
    }

    @Test("with an identical twin attached, only the chosen port matches")
    func twinPinsThePort() {
        var chosen = drive
        chosen.locationId = 0x0120_0000
        var twin = drive
        twin.locationId = 0x0110_0000
        #expect(
            USBPassthroughPolicy.properties(for: chosen, connected: [twin, chosen])
                == "vendorid=0x05e3,productid=0x0764,hostbus=1,hostport=2"
        )

        // QEMU treats hostbus=0 as any bus, so the first controller relies on
        // the port path alone.
        chosen.locationId = 0x0020_0000
        #expect(
            USBPassthroughPolicy.properties(for: chosen, connected: [twin, chosen])
                == "vendorid=0x05e3,productid=0x0764,hostport=2"
        )
    }

    @Test("twins the port cannot tell apart leave both with macOS")
    func indistinguishableTwinsPassNothing() {
        // Each Apple Silicon port is its own controller, so identical sticks in
        // two ports both sit at port 1; on bus 0 QEMU cannot pin the bus.
        var chosen = drive
        chosen.locationId = 0x0010_0000
        var twin = drive
        twin.locationId = 0x0110_0000
        let configuration = USBPassthroughLaunchConfiguration.make(
            baseEnvironment: [:],
            preference: USBDevicePreference(device: chosen, isEnabled: true),
            connected: [chosen, twin]
        )
        #expect(configuration.device == nil)
        #expect(configuration.environment[USBPassthroughPolicy.environmentKey] == nil)

        let state = USBDeviceMenuState.make(
            preference: USBDevicePreference(device: chosen, isEnabled: true),
            connected: [chosen, twin],
            environment: [:]
        )
        #expect(state.isAmbiguous)
        let presentation = StartMenuPresentation.usbDevice(state: state)
        #expect(!presentation.isGranted)
        #expect(presentation.detail.contains("unplug one"))
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

        var located = iPhone
        located.locationId = 0x0120_0000
        store.save(USBDevicePreference(device: located, isEnabled: true))
        #expect(store.load() == USBDevicePreference(device: located, isEnabled: true))

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

    @Test("the row promises nothing macOS will not give up")
    func rowSaysMacOSKeepsTheDevice() {
        let attached = USBDeviceMenuState.make(
            preference: USBDevicePreference(device: drive, isEnabled: true),
            connected: [drive],
            environment: [:]
        )
        // Unprivileged, libusb_detach_kernel_driver returns LIBUSB_ERROR_ACCESS
        // for every device macOS has a driver for, so a row saying Omarchy
        // takes the device over would be a false promise.
        let detail = StartMenuPresentation.usbDevice(state: attached).detail
        #expect(detail.contains("macOS keeps"))
        #expect(!detail.lowercased().contains("claims"))
    }
}
