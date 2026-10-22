import Foundation

enum NativeInstallExports {
    static let detail = "Move your files to Omarchy installed on this Mac. In Omarchy, choose Setup → Move to Native Install; the export then appears in Exports, where the Omarchy installer finds it."

    static func folder(applicationSupport: URL) -> URL {
        applicationSupport
            .appendingPathComponent("Try Omarchy", isDirectory: true)
            .appendingPathComponent("Exports", isDirectory: true)
            .standardizedFileURL
    }

    static func defaultFolder(fileManager: FileManager = .default) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first.map {
            folder(applicationSupport: $0)
        }
    }
}
