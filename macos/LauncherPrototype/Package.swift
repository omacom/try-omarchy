// swift-tools-version: 6.0
import PackageDescription

// Visual prototype of the native launcher. It uses mock state only and is not
// part of the app build; run it with `swift run` from this directory.
let package = Package(
    name: "LauncherPrototype",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "LauncherPrototype"),
    ],
    swiftLanguageModes: [.v5]
)
