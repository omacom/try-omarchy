import Foundation
import IOKit.hid

enum FIDODevicePolicy {
    static let environmentKey = "OMARCHY_QEMU_GPU_FIDO_DEVICE"

    static func registryID(_ selector: String) -> UInt64? {
        guard selector.hasPrefix("0x"), (3...18).contains(selector.count),
              selector.dropFirst(2).allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let id = UInt64(selector.dropFirst(2), radix: 16), id != 0 else { return nil }
        return id
    }

    static func selected(registryID: UInt64, from devices: [FIDODeviceIdentity]) -> FIDODeviceIdentity? {
        let matches = devices.filter { $0.registryID == registryID }
        guard matches.count == 1, matches[0].isSupported else { return nil }
        return matches[0]
    }

    static func supports(transport: String, usagePage: Int, usage: Int,
                         inputBytes: Int, outputBytes: Int, descriptor: Data) -> Bool {
        transport == "USB" && usagePage == 0xf1d0 && usage == 1
            && inputBytes == 64 && outputBytes == 64 && supportsDescriptor(descriptor)
    }

    static func supportsDescriptor(_ descriptor: Data) -> Bool {
        struct Globals {
            var page: UInt32 = 0
            var size: UInt32 = 0
            var count: UInt32 = 0
        }
        let bytes = Array(descriptor)
        guard !bytes.isEmpty, bytes.count <= 4096 else { return false }
        var globals = Globals()
        var stack: [Globals] = []
        var usage: UInt32?
        var depth = 0
        var collections = 0
        var inputBits = 0
        var outputBits = 0
        var offset = 0
        while offset < bytes.count {
            let prefix = bytes[offset]
            offset += 1
            guard prefix != 0xfe else { return false }
            let size = [0, 1, 2, 4][Int(prefix & 3)]
            guard offset + size <= bytes.count else { return false }
            let value = bytes[offset..<(offset + size)].enumerated().reduce(UInt32(0)) {
                $0 | (UInt32($1.element) << ($1.offset * 8))
            }
            offset += size
            let type = (prefix >> 2) & 3
            let tag = prefix >> 4
            if type == 1 {
                switch tag {
                case 0: globals.page = value
                case 7: globals.size = value
                case 8: return false
                case 9: globals.count = value
                case 10:
                    guard stack.count < 8 else { return false }
                    stack.append(globals)
                case 11:
                    guard let previous = stack.popLast() else { return false }
                    globals = previous
                default: break
                }
            } else if type == 2 {
                guard tag == 0 else { return false }
                usage = value
            } else if type == 0 {
                switch tag {
                case 10:
                    if depth == 0 {
                        guard value == 1, collections == 0,
                              globals.page == 0xf1d0, usage == 1 else { return false }
                        collections += 1
                    } else if value == 1 {
                        return false
                    }
                    depth += 1
                    guard depth <= 8 else { return false }
                case 12:
                    guard depth > 0 else { return false }
                    depth -= 1
                case 8, 9:
                    guard depth > 0, globals.page == 0xf1d0,
                          usage == (tag == 8 ? 0x20 : 0x21),
                          globals.size > 0, globals.size <= 32,
                          globals.count > 0, globals.count <= 512 else { return false }
                    let bits = Int(globals.size * globals.count)
                    if tag == 8 { inputBits += bits } else { outputBits += bits }
                    guard inputBits <= 512, outputBits <= 512 else { return false }
                default: return false
                }
                usage = nil
            } else {
                return false
            }
        }
        return depth == 0 && stack.isEmpty && collections == 1 && inputBits == 512 && outputBits == 512
    }
}

struct FIDODeviceIdentity: Equatable {
    let registryID: UInt64
    let name: String
    let isSupported: Bool

    var selector: String { String(format: "0x%016llx", registryID) }
}

enum HostFIDODevices {
    static func connected() -> [FIDODeviceIdentity] {
        devices().compactMap { identity($0) }.sorted { $0.registryID < $1.registryID }
    }

    static func open(registryID: UInt64, received: @escaping ([UInt8]) -> Void,
                     failed: @escaping () -> Void) throws -> FIDOReportDevice {
        let available = devices().compactMap { device in identity(device).map { (device, $0) } }
        guard let chosen = FIDODevicePolicy.selected(registryID: registryID, from: available.map { $0.1 }),
              let selected = available.first(where: { $0.1 == chosen })?.0 else {
            throw HelperError.io("the selected USB FIDO interface is absent or has an unsupported report layout; select it again")
        }
        return try MacFIDODevice(device: selected, received: received, failed: failed)
    }

    private static func devices() -> [IOHIDDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDDeviceUsagePageKey: 0xf1d0,
            kIOHIDDeviceUsageKey: 1,
            kIOHIDTransportKey: "USB",
        ] as CFDictionary)
        return (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>).map(Array.init) ?? []
    }

    private static func identity(_ device: IOHIDDevice) -> FIDODeviceIdentity? {
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id) == KERN_SUCCESS,
              id != 0 else { return nil }
        func integer(_ key: String) -> Int { (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0 }
        let supported = FIDODevicePolicy.supports(
            transport: IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "",
            usagePage: integer(kIOHIDPrimaryUsagePageKey), usage: integer(kIOHIDPrimaryUsageKey),
            inputBytes: integer(kIOHIDMaxInputReportSizeKey), outputBytes: integer(kIOHIDMaxOutputReportSizeKey),
            descriptor: IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data ?? Data()
        )
        return FIDODeviceIdentity(registryID: id,
                                  name: IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "USB FIDO key",
                                  isSupported: supported)
    }
}

private final class MacFIDODevice: FIDOReportDevice {
    private var device: IOHIDDevice?
    private let buffer = NSMutableData(length: 64)!
    private let received: ([UInt8]) -> Void
    private let failed: () -> Void

    init(device: IOHIDDevice, received: @escaping ([UInt8]) -> Void, failed: @escaping () -> Void) throws {
        self.received = received
        self.failed = failed
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) == kIOReturnSuccess else {
            throw HelperError.io("cannot take temporary ownership of the selected FIDO interface")
        }
        self.device = device
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer.mutableBytes.assumingMemoryBound(to: UInt8.self), 64, { context, result, _, type, id, report, count in
            guard let context else { return }
            let owner = Unmanaged<MacFIDODevice>.fromOpaque(context).takeUnretainedValue()
            guard result == kIOReturnSuccess, type == kIOHIDReportTypeInput, id == 0, count == 64 else {
                owner.failed()
                return
            }
            owner.received(Array(UnsafeBufferPointer(start: report, count: 64)))
        }, context)
        IOHIDDeviceRegisterRemovalCallback(device, { context, _, _ in
            guard let context else { return }
            Unmanaged<MacFIDODevice>.fromOpaque(context).takeUnretainedValue().failed()
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    deinit {
        close()
    }

    func write(_ report: [UInt8]) throws {
        guard let device, report.count == 64 else { throw HelperError.io("FIDO interface is closed") }
        let result = report.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, $0.baseAddress!, $0.count)
        }
        guard result == kIOReturnSuccess else { throw HelperError.io("cannot write the selected FIDO interface") }
    }

    func close() {
        guard let opened = device else { return }
        device = nil
        IOHIDDeviceRegisterInputReportCallback(opened, buffer.mutableBytes.assumingMemoryBound(to: UInt8.self), 64, nil, nil)
        IOHIDDeviceRegisterRemovalCallback(opened, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(opened, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(opened, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
    }
}
