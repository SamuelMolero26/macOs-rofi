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
        .target(name: "RofiAppKit", dependencies: ["RofiCore"]),
        .executableTarget(name: "rofi", dependencies: ["RofiCore", "RofiAppKit"]),
        .testTarget(name: "RofiCoreTests", dependencies: ["RofiCore"]),
    ]
)
