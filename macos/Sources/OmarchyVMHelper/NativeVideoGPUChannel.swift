import CoreVideo
import Darwin
import Foundation
import IOSurface

/// Host-only channel: an IOSurface ID is never accepted from the guest.
/// QEMU submits copies into the guest's existing VirGL textures before
/// acknowledging and retains the capability until GPU completion. This call
/// keeps the decoder pixel buffer alive until QEMU has taken that ownership.
final class NativeVideoGPUChannel: @unchecked Sendable {
    private let descriptor: Int32
    private var surfaceService: mach_port_t = 0
    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private var reported = false
    private var reportedRejection = false

    init(path: String, targetPID: pid_t) throws {
        descriptor = try NativeBridgeSocket.connectSecure(path: path, label: "video GPU bridge")
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        guard setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            Darwin.close(descriptor)
            throw HelperError.io("cannot set video GPU write timeout")
        }
        do {
            // Like shm_open, this public C function is omitted by the Swift
            // Darwin module on some SDK versions; retain its exact C ABI.
            typealias Lookup = @convention(c) (mach_port_t, UnsafePointer<CChar>, UnsafeMutablePointer<mach_port_t>) -> kern_return_t
            guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "bootstrap_look_up") else {
                throw HelperError.io("Mach service lookup is unavailable")
            }
            let lookup = unsafeBitCast(symbol, to: Lookup.self)
            guard let greeting = try NativeVideoMessage.readExactly(128, from: descriptor, allowEOF: false, initialTimeout: 5_000),
                  greeting.prefix(8) == Data([0x54, 0x4f, 0x47, 0x4d, 1, 0, 0, 0]),
                  let end = greeting[8...].firstIndex(of: 0),
                  let name = String(data: greeting[8..<end], encoding: .utf8),
                  name.hasPrefix("com.tryomarchy.video.\(targetPID)."),
                  name.withCString({ lookup(bootstrap_port, $0, &surfaceService) }) == KERN_SUCCESS else {
                throw HelperError.io("invalid video GPU capability channel")
            }
        } catch { Darwin.close(descriptor); throw error }
    }
    deinit {
        if surfaceService != 0 { mach_port_deallocate(mach_task_self_, surfaceService) }
        Darwin.close(descriptor)
    }

    func copy(_ image: CVPixelBuffer, yResource: UInt32, uvResource: UInt32, format: UInt32) throws -> Bool {
        guard let surface = CVPixelBufferGetIOSurface(image)?.takeUnretainedValue() else { return false }
        lock.lock()
        defer { lock.unlock() }
        sequence &+= 1
        let surfacePort = IOSurfaceCreateMachPort(surface)
        guard surfacePort != 0 else { return false }
        defer { mach_port_deallocate(mach_task_self_, surfacePort) }
        var capability = Data()
        func machAppend<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { capability.append(contentsOf: $0) }
        }
        // mach_msg_header_t, one mach_msg_port_descriptor_t, then the token.
        machAppend(UInt32(MACH_MSGH_BITS_COMPLEX) | UInt32(MACH_MSG_TYPE_COPY_SEND))
        machAppend(UInt32(48)); machAppend(surfaceService)
        machAppend(UInt32(0)); machAppend(UInt32(0)); machAppend(UInt32(0x544f5647))
        machAppend(UInt32(1)); machAppend(surfacePort); machAppend(UInt32(0))
        machAppend(UInt16(0)); machAppend(UInt8(MACH_MSG_TYPE_COPY_SEND)); machAppend(UInt8(MACH_MSG_PORT_DESCRIPTOR))
        machAppend(sequence)
        let sent = capability.withUnsafeMutableBytes { bytes in
            mach_msg(bytes.bindMemory(to: mach_msg_header_t.self).baseAddress!,
                     MACH_SEND_MSG | MACH_SEND_TIMEOUT, 48, 0, 0, 5_000, 0)
        }
        guard sent == MACH_MSG_SUCCESS else { throw HelperError.io("cannot transfer decoded IOSurface capability (\(sent))") }
        var request = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { request.append(contentsOf: $0) }
        }
        append(UInt32(0x47564f54)); append(UInt16(1)); append(UInt16(0))
        append(sequence); append(IOSurfaceGetID(surface)); append(yResource); append(uvResource)
        append(UInt32(CVPixelBufferGetWidth(image))); append(UInt32(CVPixelBufferGetHeight(image))); append(format)
        try NativeBridgeSocket.writeAll(request, to: descriptor, label: "video GPU")
        guard var response = try NativeVideoMessage.readExactly(40, from: descriptor, allowEOF: false, initialTimeout: 5_000) else {
            throw HelperError.io("video GPU channel closed")
        }
        let status = response.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: 6, as: UInt16.self)) }
        response[6] = 0; response[7] = 0
        guard response == request else { throw HelperError.io("video GPU acknowledgement does not match its frame") }
        if status == 0 && !reported {
            reported = true
            fputs("[video-bridge] IOSurface GPU frame transfer active\n", stderr)
        }
        if status != 0 && !reportedRejection {
            reportedRejection = true
            fputs("[video-bridge] IOSurface GPU import unavailable (\(status)); using shared frames\n", stderr)
        }
        return status == 0
    }
}
