import Foundation

/// The outbox for exports to a native install. Only the Omarchy installer
/// takes exports, so only the run mode asks the launcher for it.
enum NativeInstallExports {
    static let environmentKey = "OMARCHY_QEMU_GPU_NATIVE_EXPORTS"
}
