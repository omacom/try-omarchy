import Foundation

/// The outbox for exports to a native install. Only the Omarchy installer
/// takes exports, so only the run mode asks the launcher for it, and only
/// when the installer's configuration asks.
enum NativeInstallExports {
    static let environmentKey = "OMARCHY_QEMU_GPU_NATIVE_EXPORTS"
}
