// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BrainFog",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "BrainFog", targets: ["BrainFog"]),
        .library(name: "BrainFogCore", targets: ["BrainFogCore"]),
    ],
    targets: [
        .target(name: "BrainFogCore"),
        .executableTarget(
            name: "BrainFog",
            dependencies: ["BrainFogCore"]
        ),
        .executableTarget(
            name: "brainfog-cli",
            dependencies: ["BrainFogCore"]
        ),
        .testTarget(
            name: "BrainFogCoreTests",
            dependencies: ["BrainFogCore"]
        ),
    ]
)
