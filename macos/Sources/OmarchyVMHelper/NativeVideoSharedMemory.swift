import Darwin
import Foundation

/// A dedicated frame aperture: this is never the virtual machine's RAM.
/// QEMU creates the private POSIX object and unlinks it when the VM exits.
final class NativeVideoSharedMemory {
    static let slotSize = 64 * 1024 * 1024
    static let slotCount = 8
    static let size = slotSize * slotCount
    private let descriptor: Int32
    fileprivate let address: UnsafeMutableRawPointer
    private let lock = NSLock()
    private var used = Set<Int>()

    private static func openOwned(name: String, allowMissing: Bool = false, allowEmpty: Bool = false) throws -> Int32 {
        guard name.hasPrefix("/tovd."), name.utf8.count <= 31,
              name.dropFirst().allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else {
            throw HelperError.io("invalid video shared memory name")
        }
        // Darwin declares shm_open variadic. Without O_CREAT it has exactly
        // two arguments; resolve that C signature because Swift cannot import it.
        typealias OpenSharedMemory = @convention(c) (UnsafePointer<CChar>, Int32) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "shm_open") else {
            throw HelperError.io("POSIX shared memory is unavailable")
        }
        let openSharedMemory = unsafeBitCast(symbol, to: OpenSharedMemory.self)
        let fd = name.withCString { openSharedMemory($0, O_RDWR) }
        if fd < 0 && allowMissing && errno == ENOENT { return -1 }
        guard fd >= 0 else { throw HelperError.io("cannot open video shared memory") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0, (info.st_size == Self.size || (allowEmpty && info.st_size == 0)) else {
            Darwin.close(fd)
            throw HelperError.io("video shared memory must be private, owned and 512 MiB")
        }
        return fd
    }

    static func unlinkIfOwned(name: String) throws {
        let fd = try openOwned(name: name, allowMissing: true, allowEmpty: true)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        guard name.withCString({ shm_unlink($0) }) == 0 || errno == ENOENT else {
            throw HelperError.io("cannot unlink video shared memory")
        }
    }

    init(name: String) throws {
        // QEMU publishes its chardev before realizing the PCI aperture. Wait
        // only for a missing/empty object; ownership and permission failures
        // remain immediate errors. Use a monotonic deadline across host sleep.
        let deadline = ContinuousClock.now + .seconds(5)
        var fd: Int32 = -1
        while true {
            fd = try Self.openOwned(name: name, allowMissing: true, allowEmpty: true)
            if fd >= 0 {
                var info = stat()
                if fstat(fd, &info) == 0 && info.st_size == Self.size { break }
                Darwin.close(fd)
            }
            guard ContinuousClock.now < deadline else {
                throw HelperError.io("QEMU did not initialize video shared memory within five seconds")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let mapped = mmap(nil, Self.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        guard mapped != MAP_FAILED, let mapped else {
            Darwin.close(fd)
            throw HelperError.io("cannot map video shared memory")
        }
        descriptor = fd
        address = mapped
    }

    deinit { munmap(address, Self.size); Darwin.close(descriptor) }

    func allocateSlot() throws -> NativeVideoSharedSlot {
        lock.lock()
        defer { lock.unlock() }
        guard let index = (0..<Self.slotCount).first(where: { !used.contains($0) }) else {
            throw HelperError.io("video shared memory has no free frame slot")
        }
        used.insert(index)
        return NativeVideoSharedSlot(memory: self, index: index)
    }

    fileprivate func release(_ index: Int) {
        lock.lock()
        defer { lock.unlock() }
        // Do not expose pixels from a previous decoder to the next session.
        memset(address.advanced(by: index * Self.slotSize), 0, Self.slotSize)
        used.remove(index)
    }
}

/// The guest consumes each frame before sending the next request. Publication
/// completes before the descriptor is sent through the ordered virtio channel.
final class NativeVideoSharedSlot {
    private let memory: NativeVideoSharedMemory
    private let index: Int

    fileprivate init(memory: NativeVideoSharedMemory, index: Int) {
        self.memory = memory
        self.index = index
    }

    deinit { memory.release(index) }

    func write(length: Int, fill: (UnsafeMutableRawPointer) throws -> Void) throws -> Data {
        guard length > 0, length <= NativeVideoSharedMemory.slotSize else {
            throw HelperError.io("decoded frame does not fit shared memory")
        }
        let offset = index * NativeVideoSharedMemory.slotSize
        try fill(memory.address.advanced(by: offset))
        // A descriptor consists of offset (u64), byte length (u32), reserved (u32).
        var descriptor = Data(count: 16)
        descriptor.withUnsafeMutableBytes {
            $0.storeBytes(of: UInt64(offset).littleEndian, toByteOffset: 0, as: UInt64.self)
            $0.storeBytes(of: UInt32(length).littleEndian, toByteOffset: 8, as: UInt32.self)
        }
        return descriptor
    }
}
