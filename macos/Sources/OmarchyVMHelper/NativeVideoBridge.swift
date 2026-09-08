import CoreMedia
import CoreVideo
import Darwin
import Foundation
import VideoToolbox

/// Decodes guest-supplied access units using the Mac media engine.
/// No paths, URLs or host file operations are exposed by this protocol.
final class NativeVideoBridge: @unchecked Sendable {
    private let descriptor: Int32
    private let targetPID: pid_t
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var stopped = false
    private var sessions: [UInt32: NativeVideoDecoder] = [:]
    private let sharedMemory: NativeVideoSharedMemory?
    private let gpuChannel: NativeVideoGPUChannel?

    init(targetPID: pid_t, socketPath: String, sharedMemoryName: String? = nil, gpuSocketPath: String? = nil) throws {
        guard let identity = KernelProcessIdentity.capture(processIdentifier: targetPID),
              identity.isQEMUSystemProcess else {
            throw HelperError.io("native video bridge target is not a QEMU system process")
        }
        self.targetPID = targetPID
        sharedMemory = try sharedMemoryName.map { try NativeVideoSharedMemory(name: $0) }
        gpuChannel = try gpuSocketPath.map { try NativeVideoGPUChannel(path: $0, targetPID: targetPID) }
        descriptor = try NativeBridgeSocket.connectSecure(path: socketPath, label: "video bridge")
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        guard setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            Darwin.close(descriptor)
            throw HelperError.io("cannot set video channel write timeout")
        }
    }

    deinit { stop(); Darwin.close(descriptor) }

    func stop() {
        stateLock.lock()
        defer { stateLock.unlock() }
        if !stopped {
            stopped = true
            Darwin.shutdown(descriptor, SHUT_RDWR)
        }
    }

    func run() throws {
        let watcher = DispatchSource.makeProcessSource(identifier: targetPID, eventMask: .exit,
                                                        queue: .global(qos: .userInitiated))
        watcher.setEventHandler { [weak self] in self?.stop() }
        watcher.resume()
        defer { watcher.cancel(); sessions.removeAll() }
        while let request = try NativeVideoMessage.read(from: descriptor) {
            do { try handle(request) }
            catch {
                // A bad codec stream destroys only its own decoder. Framing
                // errors, handled by read(), terminate the entire connection.
                sessions.removeValue(forKey: request.session)
                try send(NativeVideoMessage(
                    operation: .error, session: request.session, token: request.token,
                    payload: Data(error.localizedDescription.prefix(1024).utf8)
                ))
            }
        }
    }

    private func send(_ message: NativeVideoMessage) throws {
        let data = try message.encoded()
        writeLock.lock()
        defer { writeLock.unlock() }
        try NativeBridgeSocket.writeAll(data, to: descriptor, label: "video")
    }

    private func handle(_ request: NativeVideoMessage) throws {
        if request.operation == .reset {
            guard request.session == 0, request.arg0 == 0, request.arg1 == 0,
                  request.flags == 0, request.payload.isEmpty else { throw HelperError.io("invalid video reset") }
            sessions.removeAll()
            try send(NativeVideoMessage(operation: .resetComplete, session: 0, token: request.token))
            return
        }
        guard request.session != 0, (request.operation == .open
            ? request.flags <= 1 && request.arg0 <= 2
            : request.operation == .decode && request.flags == 4
                ? gpuChannel != nil && request.arg0 != 0 && request.arg1 != 0 && request.arg0 != request.arg1
                : request.flags == 0 && request.arg0 == 0 && request.arg1 == 0) else {
            throw HelperError.io("invalid video request fields")
        }
        switch request.operation {
        case .open:
            guard sessions[request.session] == nil, sessions.count < 8 else {
                throw HelperError.io("video decoder session is already open or the limit of 8 was reached")
            }
            var storage: NativeVideoSharedSlot?
            if request.flags == 1 {
                guard let sharedMemory else { throw HelperError.io("shared video frames are not configured") }
                storage = try sharedMemory.allocateSlot()
            }
            let decoder = try NativeVideoDecoder(configuration: request.payload, codec: request.arg0, dimensions: request.arg1, frameStorage: storage, gpuChannel: storage == nil ? nil : gpuChannel) { [weak self, storage] frame in
                var message = frame
                message.session = request.session
                guard let self else { throw HelperError.io("video bridge was stopped") }
                try self.send(message)
                if storage != nil {
                    guard let release = try NativeVideoMessage.read(from: self.descriptor, timeoutMilliseconds: 5_000),
                          release.operation == .release, release.session == request.session,
                          release.token == message.token, release.payload.isEmpty,
                          release.arg0 == 0, release.arg1 == 0, release.flags == 0 else {
                        throw HelperError.io("video frame must be released before its slot is reused")
                    }
                }
            }
            sessions[request.session] = decoder
            try send(NativeVideoMessage(
                operation: .opened, session: request.session, token: request.token,
                arg0: UInt32(decoder.width), arg1: UInt32(decoder.height),
                flags: decoder.formatFlag | 0x100 | (storage == nil ? 0 : 0x200) | (storage != nil && gpuChannel != nil ? 0x400 : 0)
            ))
        case .decode:
            guard let decoder = sessions[request.session] else { throw HelperError.io("video session is not open") }
            try decoder.decode(request.payload, token: request.token,
                               gpuTargets: request.flags == 4 ? (request.arg0, request.arg1) : nil)
            try send(NativeVideoMessage(operation: .decoded, session: request.session, token: request.token))
        case .drain:
            guard request.payload.isEmpty, let decoder = sessions[request.session] else {
                throw HelperError.io("invalid video drain request")
            }
            try decoder.drain()
            try send(NativeVideoMessage(operation: .drained, session: request.session, token: request.token))
        case .close:
            guard request.payload.isEmpty else { throw HelperError.io("invalid video close request") }
            sessions.removeValue(forKey: request.session)
            try send(NativeVideoMessage(operation: .closed, session: request.session, token: request.token))
        default:
            throw HelperError.io("unsupported video operation")
        }
    }
}

final class NativeVideoDecoder: @unchecked Sendable {
    let width: Int
    let height: Int
    let formatFlag: UInt32
    private let hevcConfiguration: NativeHEVCConfiguration?
    private let tenBit: Bool
    private let format: CMVideoFormatDescription
    private var decoder: VTDecompressionSession?
    private let output: (NativeVideoMessage) throws -> Void
    private let frameStorage: NativeVideoSharedSlot?
    private let errorLock = NSLock()
    private var outputError: Error?
    private let gpuChannel: NativeVideoGPUChannel?
    private var gpuTargets: [UInt64: (UInt32, UInt32)] = [:]

    init(configuration data: Data, codec: UInt32 = 0, dimensions: UInt32 = 0,
         frameStorage: NativeVideoSharedSlot? = nil,
         gpuChannel: NativeVideoGPUChannel? = nil,
         output: @escaping (NativeVideoMessage) throws -> Void) throws {
        self.output = output
        self.frameStorage = frameStorage
        self.gpuChannel = gpuChannel
        var description: CMFormatDescription?
        if codec == 0 {
            let configuration = try NativeHEVCConfiguration(data)
            hevcConfiguration = configuration
            tenBit = configuration.tenBit
            let storage = configuration.parameterSets.map { $0 as NSData }
            let pointers = storage.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
            let lengths = storage.map { $0.length }
            let result = pointers.withUnsafeBufferPointer { p in
                lengths.withUnsafeBufferPointer { n in
                    CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: storage.count,
                        parameterSetPointers: p.baseAddress!, parameterSetSizes: n.baseAddress!,
                        nalUnitHeaderLength: Int32(configuration.nalLengthSize), extensions: nil,
                        formatDescriptionOut: &description
                    )
                }
            }
            guard result == noErr else { throw HelperError.io("HEVC format rejected (\(result))") }
        } else if codec == 1 {
            let configuration = try NativeAV1Configuration(data)
            hevcConfiguration = nil
            tenBit = configuration.tenBit
            let extensions: [String: Any] = [
                kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: ["av1C": data],
            ]
            let result = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_AV1,
                width: Int32(dimensions & 0xffff), height: Int32(dimensions >> 16),
                extensions: extensions as CFDictionary, formatDescriptionOut: &description
            )
            guard result == noErr else { throw HelperError.io("AV1 format rejected (\(result))") }
        } else if codec == 2 {
            let configuration = try NativeVP9Configuration(data)
            hevcConfiguration = nil
            tenBit = configuration.tenBit
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
            let extensions: [String: Any] = [
                kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: ["vpcC": data],
            ]
            let result = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_VP9,
                width: Int32(dimensions & 0xffff), height: Int32(dimensions >> 16),
                extensions: extensions as CFDictionary, formatDescriptionOut: &description
            )
            guard result == noErr else { throw HelperError.io("VP9 format rejected (\(result))") }
        } else { throw HelperError.io("unsupported video codec") }
        guard let description else { throw HelperError.io("missing video format") }
        formatFlag = tenBit ? 2 : 1
        format = description
        let size = CMVideoFormatDescriptionGetDimensions(description)
        width = Int(size.width)
        height = Int(size.height)
        guard width > 0, height > 0, width <= 8192, height <= 4320,
              width % 2 == 0, height % 2 == 0,
              width * height * 3 / (tenBit ? 1 : 2) <= NativeVideoMessage.maxPayload else {
            throw HelperError.io("unsupported video dimensions")
        }
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { context, _, status, _, image, pts, _ in
                guard let context else { return }
                let owner = Unmanaged<NativeVideoDecoder>.fromOpaque(context).takeUnretainedValue()
                owner.didDecode(status: status, image: image, pts: pts)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let specifications: [String: Any] = [
            kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: true,
        ]
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: tenBit
                ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: specifications as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callback, decompressionSessionOut: &decoder
        )
        guard status == noErr, let decoder else {
            throw HelperError.io("hardware video decoder unavailable (\(status))")
        }
        var hardware: Unmanaged<CFTypeRef>?
        let probe = VTSessionCopyProperty(
            decoder, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
            allocator: kCFAllocatorDefault, valueOut: &hardware
        )
        let hardwareValue = hardware?.takeRetainedValue()
        guard probe == noErr, (hardwareValue as? NSNumber)?.boolValue == true else {
            VTDecompressionSessionInvalidate(decoder)
            self.decoder = nil
            throw HelperError.io("VideoToolbox did not confirm hardware video decoding")
        }
        let codecName = codec == 0 ? "HEVC" : codec == 1 ? "AV1" : "VP9"
        fputs("[video-bridge] \(codecName) \(width)x\(height) \(tenBit ? 10 : 8)-bit: UsingHardwareAcceleratedVideoDecoder=true\n", stderr)
    }

    deinit {
        if let decoder {
            VTDecompressionSessionWaitForAsynchronousFrames(decoder)
            VTDecompressionSessionInvalidate(decoder)
        }
    }

    func decode(_ data: Data, token: UInt64, gpuTargets targets: (UInt32, UInt32)? = nil) throws {
        guard let decoder else { throw HelperError.io("video decoder was closed") }
        guard !data.isEmpty else { throw HelperError.io("empty compressed access unit") }
        try hevcConfiguration?.validatePacket(data)
        errorLock.lock()
        let hasCapacity = gpuTargets.count < 256
        if hasCapacity { gpuTargets[token] = targets }
        errorLock.unlock()
        guard hasCapacity else { throw HelperError.io("too many pending GPU video frames") }
        var block: CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: data.count, flags: 0, blockBufferOut: &block
        ))
        guard let block else { throw HelperError.io("cannot allocate compressed video buffer") }
        try data.withUnsafeBytes { bytes in
            try check(CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count
            ))
        }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(bitPattern: token), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var size = data.count
        var sample: CMSampleBuffer?
        try check(CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
        ))
        guard let sample else { throw HelperError.io("cannot create compressed video sample") }
        try check(VTDecompressionSessionDecodeFrame(
            decoder, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: nil
        ))
        try checkOutput()
    }

    func drain() throws {
        guard let decoder else { throw HelperError.io("video decoder was closed") }
        try check(VTDecompressionSessionFinishDelayedFrames(decoder))
        try check(VTDecompressionSessionWaitForAsynchronousFrames(decoder))
        try checkOutput()
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw HelperError.io("VideoToolbox failed (\(status))") }
    }

    private func checkOutput() throws {
        errorLock.lock()
        let error = outputError
        errorLock.unlock()
        if let error { throw error }
    }

    private func didDecode(status: OSStatus, image: CVImageBuffer?, pts: CMTime) {
        do {
            try check(status)
            guard let image else { throw HelperError.io("VideoToolbox returned no decoded frame") }
            let pixelFormat = CVPixelBufferGetPixelFormatType(image)
            let expected = tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            guard pixelFormat == expected, CVPixelBufferGetWidth(image) == width,
                  CVPixelBufferGetHeight(image) == height, CVPixelBufferGetPlaneCount(image) == 2 else {
                throw HelperError.io("VideoToolbox returned an unexpected frame layout")
            }
            errorLock.lock()
            let targets = gpuTargets.removeValue(forKey: UInt64(bitPattern: pts.value))
            errorLock.unlock()
            if let targets, let gpuChannel,
               try gpuChannel.copy(image, yResource: targets.0, uvResource: targets.1, format: formatFlag) {
                try output(NativeVideoMessage(operation: .frame, session: 0, token: UInt64(bitPattern: pts.value),
                    arg0: UInt32(width), arg1: UInt32(height), flags: formatFlag | 0x600, payload: Data(count: 16)))
                return
            }
            let locked = CVPixelBufferLockBaseAddress(image, .readOnly)
            guard locked == kCVReturnSuccess else { throw HelperError.io("cannot access decoded frame") }
            defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
            let rowBytes = width * (tenBit ? 2 : 1)
            let fill: (UnsafeMutableRawPointer) throws -> Void = { [height] destination in
                var offset = 0
                for plane in 0..<2 {
                    guard let source = CVPixelBufferGetBaseAddressOfPlane(image, plane) else {
                        throw HelperError.io("decoded frame has no plane storage")
                    }
                    let rows = plane == 0 ? height : height / 2
                    let stride = CVPixelBufferGetBytesPerRowOfPlane(image, plane)
                    guard stride >= rowBytes, CVPixelBufferGetHeightOfPlane(image, plane) >= rows else {
                        throw HelperError.io("decoded frame has an invalid plane stride")
                    }
                    for row in 0..<rows {
                        memcpy(destination.advanced(by: offset), source.advanced(by: row * stride), rowBytes)
                        offset += rowBytes
                    }
                }
            }
            let length = rowBytes * height * 3 / 2
            var payload: Data
            if let frameStorage {
                payload = try frameStorage.write(length: length, fill: fill)
            } else {
                payload = Data(count: length)
                try payload.withUnsafeMutableBytes { try fill($0.baseAddress!) }
            }
            try output(NativeVideoMessage(
                operation: .frame, session: 0, token: UInt64(bitPattern: pts.value),
                arg0: UInt32(width), arg1: UInt32(height), flags: formatFlag | (frameStorage == nil ? 0 : 0x200), payload: payload
            ))
        } catch {
            errorLock.lock()
            outputError = error
            errorLock.unlock()
        }
    }
}
