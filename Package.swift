// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MIQ",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "MIQCore",
            targets: ["MIQCore"]
        )
    ],
    targets: [
        .target(
            name: "MIQCore"
        ),
        .testTarget(
            name: "MIQCoreTests",
            dependencies: ["MIQCore"]
        )
    ]
)