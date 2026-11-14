// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OmarchyVMHelper",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "omarchy-vm-helper", targets: ["OmarchyVMHelper"]),
        .library(name: "TryOmarchyKitClient", targets: ["TryOmarchyKitClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "TryOmarchyKitClient", swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "OmarchyVMHelper", dependencies: [
            "TryOmarchyKitClient",
            .product(name: "Sparkle", package: "Sparkle"),
        ], linkerSettings: [
            // The app carries Sparkle in Contents/Frameworks; the kit runs the
            // helper without it (build-kit.sh).
            .unsafeFlags([
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                "-Xlinker", "-weak_framework", "-Xlinker", "Sparkle",
            ]),
        ]),
        .testTarget(name: "OmarchyVMHelperTests", dependencies: ["OmarchyVMHelper", "TryOmarchyKitClient"]),
    ],
    swiftLanguageModes: [.v5]
)
