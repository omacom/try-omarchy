import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Native install exports")
struct NativeInstallExportsTests {
    @Test("exports live beside the VM storage in Application Support")
    func folder() {
        let applicationSupport = URL(fileURLWithPath: "/Users/someone/Library/Application Support", isDirectory: true)
        #expect(
            NativeInstallExports.folder(applicationSupport: applicationSupport).path
                == "/Users/someone/Library/Application Support/Try Omarchy/Exports"
        )
    }

    @Test("the default folder is under the user's Application Support")
    func defaultFolder() throws {
        let folder = try #require(NativeInstallExports.defaultFolder())
        #expect(folder.path.hasSuffix("/Library/Application Support/Try Omarchy/Exports"))
    }

    @Test("the row says where to start the export and where it appears")
    func detail() {
        #expect(NativeInstallExports.detail.contains("Move to Native Install"))
        #expect(NativeInstallExports.detail.contains("Exports"))
    }
}
