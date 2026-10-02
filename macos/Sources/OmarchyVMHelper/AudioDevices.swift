import AudioToolbox
import CoreAudio
import Foundation

enum HostAudioDirection: String, CaseIterable, Equatable {
    case output
    case input
}

struct HostAudioDevice: Equatable {
    let uid: String
    let displayName: String
    let sdlName: String
}

/// A direction-aware description of one CoreAudio device. Keeping this small
/// value separate from the platform enumerator makes SDL-compatible naming
/// deterministic and testable without depending on the test Mac's hardware.
struct HostAudioHardwareDescriptor: Equatable {
    let uid: String
    let outputName: String?
    let inputName: String?
}

struct HostAudioDeviceCatalog: Equatable {
    let outputDevices: [HostAudioDevice]
    let inputDevices: [HostAudioDevice]

    static let empty = Self(outputDevices: [], inputDevices: [])

    static func make(from descriptors: [HostAudioHardwareDescriptor]) -> Self {
        Self(
            outputDevices: makeDevices(from: descriptors, direction: .output),
            inputDevices: makeDevices(from: descriptors, direction: .input)
        )
    }

    func devices(for direction: HostAudioDirection) -> [HostAudioDevice] {
        switch direction {
        case .output: outputDevices
        case .input: inputDevices
        }
    }

    func device(uid: String, direction: HostAudioDirection) -> HostAudioDevice? {
        devices(for: direction).first { $0.uid == uid }
    }

    func effectiveDevice(
        direction: HostAudioDirection,
        selectedSDLName: String?,
        systemDefaultUID: String?
    ) -> HostAudioDevice? {
        if let selectedSDLName,
           let selected = devices(for: direction).first(where: { $0.sdlName == selectedSDLName }) {
            return selected
        }
        // Match SDL's fallback when a saved device has disappeared.
        guard let systemDefaultUID else { return nil }
        return device(uid: systemDefaultUID, direction: direction)
    }

    private static func makeDevices(
        from descriptors: [HostAudioHardwareDescriptor],
        direction: HostAudioDirection
    ) -> [HostAudioDevice] {
        var occurrences: [String: Int] = [:]
        var devices: [HostAudioDevice] = []

        for descriptor in descriptors {
            let rawName: String?
            switch direction {
            case .output: rawName = descriptor.outputName
            case .input: rawName = descriptor.inputName
            }
            guard let rawName else { continue }

            // SDL's CoreAudio enumerator trims trailing ASCII spaces, then its
            // generic device list adds a numeric suffix to duplicate names.
            // QEMU must receive that exact SDL-facing name, while preferences
            // retain the stable CoreAudio UID.
            let displayName = rawName.trimmingTrailingASCIISpaces()
            guard !displayName.isEmpty else { continue }
            let occurrence = occurrences[displayName, default: 0] + 1
            occurrences[displayName] = occurrence
            let sdlName = occurrence == 1
                ? displayName
                : "\(displayName) (\(occurrence))"
            devices.append(HostAudioDevice(
                uid: descriptor.uid,
                displayName: displayName,
                sdlName: sdlName
            ))
        }

        return devices.sorted {
            let comparison = $0.sdlName.localizedStandardCompare($1.sdlName)
            if comparison == .orderedSame { return $0.uid < $1.uid }
            return comparison == .orderedAscending
        }
    }
}

private extension String {
    func trimmingTrailingASCIISpaces() -> String {
        var result = self
        while result.last == " " { result.removeLast() }
        return result
    }
}

protocol HostAudioDeviceProviding {
    func catalog() -> HostAudioDeviceCatalog
}

struct CoreAudioHostAudioDeviceProvider: HostAudioDeviceProviding {
    func nominalSampleRate(direction: HostAudioDirection, selectedSDLName: String?) -> Int? {
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: direction == .output
                ? kAudioHardwarePropertyDefaultOutputDevice
                : kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let defaultStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultAddress, 0, nil, &size, &defaultID
        )
        let defaultUID = defaultStatus == noErr ? stringProperty(
            deviceID: defaultID,
            selector: kAudioDevicePropertyDeviceUID,
            scope: kAudioObjectPropertyScopeGlobal
        ) : nil
        guard let device = catalog().effectiveDevice(
            direction: direction,
            selectedSDLName: selectedSDLName,
            systemDefaultUID: defaultUID
        ), let deviceID = audioDeviceIdentifiers().first(where: {
            stringProperty(
                deviceID: $0,
                selector: kAudioDevicePropertyDeviceUID,
                scope: kAudioObjectPropertyScopeGlobal
            ) == device.uid
        }) else { return nil }

        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(
            deviceID, &rateAddress, 0, nil, &size, &rate
        ) == noErr else { return nil }
        return HostAudioSampleRate.validated(rate)
    }

    func catalog() -> HostAudioDeviceCatalog {
        let descriptors: [HostAudioHardwareDescriptor] = audioDeviceIdentifiers().compactMap { deviceID in
            guard let uid = stringProperty(
                deviceID: deviceID,
                selector: kAudioDevicePropertyDeviceUID,
                scope: kAudioObjectPropertyScopeGlobal
            ), !uid.isEmpty else { return nil }

            let outputName = directionName(
                deviceID: deviceID,
                scope: kAudioDevicePropertyScopeOutput
            )
            let inputName = directionName(
                deviceID: deviceID,
                scope: kAudioDevicePropertyScopeInput
            )
            guard outputName != nil || inputName != nil else { return nil }
            return HostAudioHardwareDescriptor(
                uid: uid,
                outputName: outputName,
                inputName: inputName
            )
        }
        return .make(from: descriptors)
    }

    private func audioDeviceIdentifiers() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr,
        size > 0,
        size.isMultiple(of: UInt32(MemoryLayout<AudioDeviceID>.size)) else {
            return []
        }

        var identifiers = [AudioDeviceID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        let status = identifiers.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                buffer.baseAddress!
            )
        }
        return status == noErr ? identifiers : []
    }

    private func directionName(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> String? {
        guard channelCount(deviceID: deviceID, scope: scope) > 0 else { return nil }
        return stringProperty(
            deviceID: deviceID,
            selector: kAudioObjectPropertyName,
            scope: scope
        )
    }

    private func channelCount(
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &size
        ) == noErr,
        size >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            return 0
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            storage
        ) == noErr else {
            return 0
        }

        let buffers = UnsafeMutableAudioBufferListPointer(
            storage.assumingMemoryBound(to: AudioBufferList.self)
        )
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func stringProperty(
        deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                pointer
            )
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}

enum HostAudioSampleRate {
    static func validated(_ rate: Double) -> Int? {
        guard rate.isFinite, rate >= 1_000, rate < 1_000_000,
              rate.rounded() == rate else { return nil }
        return Int(rate)
    }
}

enum AudioRouteSelection: Equatable {
    case systemDefault
    case device(uid: String, lastKnownName: String)

    var deviceUID: String? {
        guard case .device(let uid, _) = self else { return nil }
        return uid
    }

    var lastKnownName: String? {
        guard case .device(_, let name) = self else { return nil }
        return name
    }
}

struct AudioRoutingPreferences: Equatable {
    var output: AudioRouteSelection
    var input: AudioRouteSelection

    static let systemDefaults = Self(output: .systemDefault, input: .systemDefault)

    subscript(direction: HostAudioDirection) -> AudioRouteSelection {
        get {
            switch direction {
            case .output: output
            case .input: input
            }
        }
        set {
            switch direction {
            case .output: output = newValue
            case .input: input = newValue
            }
        }
    }
}

struct AudioRoutingPreferenceStore {
    static let key = "audioRoutingPreferences"
    static let schemaVersion = 1

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AudioRoutingPreferences {
        guard let data = defaults.data(forKey: Self.key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schemaVersion == Self.schemaVersion,
              let output = payload.output.selection,
              let input = payload.input.selection else {
            return .systemDefaults
        }
        return AudioRoutingPreferences(output: output, input: input)
    }

    func save(_ preferences: AudioRoutingPreferences) {
        let payload = Payload(
            schemaVersion: Self.schemaVersion,
            output: RoutePayload(preferences.output),
            input: RoutePayload(preferences.input)
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        // Both directions and the schema travel in one UserDefaults value, so
        // readers never observe a half-updated speaker/microphone pair.
        defaults.set(data, forKey: Self.key)
    }

    func set(_ selection: AudioRouteSelection, for direction: HostAudioDirection) {
        var preferences = load()
        preferences[direction] = selection
        save(preferences)
    }

    private struct Payload: Codable {
        let schemaVersion: Int
        let output: RoutePayload
        let input: RoutePayload
    }

    private struct RoutePayload: Codable {
        enum Kind: String, Codable {
            case systemDefault
            case device
        }

        let kind: Kind
        let uid: String?
        let lastKnownName: String?

        init(_ selection: AudioRouteSelection) {
            switch selection {
            case .systemDefault:
                kind = .systemDefault
                uid = nil
                lastKnownName = nil
            case .device(let uid, let lastKnownName):
                kind = .device
                self.uid = uid
                self.lastKnownName = lastKnownName
            }
        }

        var selection: AudioRouteSelection? {
            switch kind {
            case .systemDefault:
                guard uid == nil, lastKnownName == nil else { return nil }
                return .systemDefault
            case .device:
                guard let uid, !uid.isEmpty,
                      let lastKnownName, !lastKnownName.isEmpty else { return nil }
                return .device(uid: uid, lastKnownName: lastKnownName)
            }
        }
    }
}

struct ResolvedAudioRoutes: Equatable {
    let outputSDLName: String?
    let inputSDLName: String?
}

struct AudioLaunchConfiguration: Equatable {
    static let inheritedSDLDeviceNameKey = "SDL_AUDIO_DEVICE_NAME"
    static let outputDeviceNameKey = "OMARCHY_SDL_OUTPUT_DEVICE_NAME"
    static let inputDeviceNameKey = "OMARCHY_SDL_INPUT_DEVICE_NAME"

    let routes: ResolvedAudioRoutes
    let environment: [String: String]

    static func make(
        baseEnvironment: [String: String],
        preferences: AudioRoutingPreferences,
        catalog: HostAudioDeviceCatalog
    ) -> Self {
        let routes = ResolvedAudioRoutes(
            outputSDLName: resolve(
                preferences.output,
                direction: .output,
                catalog: catalog
            ),
            inputSDLName: resolve(
                preferences.input,
                direction: .input,
                catalog: catalog
            )
        )
        var environment = baseEnvironment
        environment.removeValue(forKey: inheritedSDLDeviceNameKey)
        environment.removeValue(forKey: outputDeviceNameKey)
        environment.removeValue(forKey: inputDeviceNameKey)
        if let outputSDLName = routes.outputSDLName {
            environment[outputDeviceNameKey] = outputSDLName
        }
        if let inputSDLName = routes.inputSDLName {
            environment[inputDeviceNameKey] = inputSDLName
        }
        return Self(routes: routes, environment: environment)
    }

    private static func resolve(
        _ selection: AudioRouteSelection,
        direction: HostAudioDirection,
        catalog: HostAudioDeviceCatalog
    ) -> String? {
        guard case .device(let uid, _) = selection else { return nil }
        return catalog.device(uid: uid, direction: direction)?.sdlName
    }
}
