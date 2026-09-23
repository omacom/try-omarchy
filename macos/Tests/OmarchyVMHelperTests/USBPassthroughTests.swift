import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("USB passthrough")
struct USBPassthroughTests {
    private let iPhone = USBDeviceIdentity(vendorId: 0x05AC, productId: 0x12A8, name: "iPhone", locationId: 0x0110_0000)
    private let drive = USBDeviceIdentity(vendorId: 0x05E3, productId: 0x0764, name: "USB Storage", locationId: 0x0120_0000)

    @Test("the launcher always receives the selected model, bus and port")
    func publishesTheChosenDevice() {
        let configuration = USBPassthroughLaunchConfiguration.make(
            baseEnvironment: [:],
            preference: USBDevicePreference(device: iPhone, isEnabled: true),
            connected: [iPhone]
        )
        #expect(configuration.device == iPhone)
        #expect(
            configuration.environment[USBPassthroughPolicy.environmentKey]
                == "vendorid=0x05ac,productid=0x12a8,hostbus=1,hostport=1"
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

    @Test("an absent selected device is never replaced by its only remaining twin")
    func absentSelectionDoesNotAuthorizeTwin() {
        var twin = drive
        twin.locationId = 0x0220_0000
        for connected in [[], [twin]] {
            let preference = USBDevicePreference(device: drive, isEnabled: true)
            let configuration = USBPassthroughLaunchConfiguration.make(
                baseEnvironment: [:], preference: preference, connected: connected
            )
            #expect(configuration.device == nil)
            #expect(configuration.environment[USBPassthroughPolicy.environmentKey] == nil)
            let state = USBDeviceMenuState.make(
                preference: preference, connected: connected, environment: [:]
            )
            #expect(!state.isConnected)
            #expect(!StartMenuPresentation.usbDevice(state: state).isGranted)
        }
    }

    @Test("the filter stays pinned whether an identical twin is attached or not")
    func selectionStaysPinned() {
        var twin = drive
        twin.locationId = 0x0220_0000
        for connected in [[drive], [twin, drive]] {
            let configuration = USBPassthroughLaunchConfiguration.make(
                baseEnvironment: [:],
                preference: USBDevicePreference(device: drive, isEnabled: true),
                connected: connected
            )
            #expect(configuration.device == drive)
            #expect(configuration.environment[USBPassthroughPolicy.environmentKey]
                == "vendorid=0x05e3,productid=0x0764,hostbus=1,hostport=2")
        }
    }

    @Test("bus zero cannot authorize future twins even while the chosen device is alone")
    func wildcardBusPassesNothing() {
        var chosen = drive
        chosen.locationId = 0x0020_0000
        for connected in [[chosen], [chosen, drive]] {
            let preference = USBDevicePreference(device: chosen, isEnabled: true)
            let configuration = USBPassthroughLaunchConfiguration.make(
                baseEnvironment: [:], preference: preference, connected: connected
            )
            #expect(configuration.device == nil)
            #expect(configuration.environment[USBPassthroughPolicy.environmentKey] == nil)
            let state = USBDeviceMenuState.make(
                preference: preference, connected: connected, environment: [:]
            )
            #expect(state.hasUnsafeLocation)
            let presentation = StartMenuPresentation.usbDevice(state: state)
            #expect(!presentation.isGranted)
            #expect(presentation.detail.contains("another port"))
        }
    }

    @Test("old or invalid locations require a new selection", arguments: [
        nil, -1, 0x1_0110_0000, 0x0100_0000,
    ] as [Int?])
    func unsafeLocationPassesNothing(location: Int?) {
        var saved = drive
        saved.locationId = location
        let configuration = USBPassthroughLaunchConfiguration.make(
            baseEnvironment: [:],
            preference: USBDevicePreference(device: saved, isEnabled: true), connected: [saved]
        )
        #expect(configuration.device == nil)
        #expect(configuration.environment[USBPassthroughPolicy.environmentKey] == nil)
    }

    @Test("a missing product string does not lose the saved physical selection")
    func productStringIsNotIdentity() {
        var unnamed = drive
        unnamed.name = ""
        let configuration = USBPassthroughLaunchConfiguration.make(
            baseEnvironment: [:],
            preference: USBDevicePreference(device: drive, isEnabled: true), connected: [unnamed]
        )
        #expect(configuration.device == drive)
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
