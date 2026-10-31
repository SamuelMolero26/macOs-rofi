// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "macOs-rofi",
    platforms: [.macOS(.v13)],
    products: [
        // Named `rofi` so existing scripts that call `rofi -dmenu` work unchanged.
        .executable(name: "rofi", targets: ["rofi"]),
    ],
    targets: [
        .target(name: "RofiCore"),
        .executableTarget(name: "rofi", dependencies: ["RofiCore"]),
        .testTarget(name: "RofiCoreTests", dependencies: ["RofiCore"]),
    ]
)
