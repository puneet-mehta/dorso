// swift-tools-version:5.9
import PackageDescription
import Foundation

// Set DORSO_NO_SPARKLE=1 to build without the Sparkle auto-updater. The
// framework is then never linked, so the resulting binary makes no network
// requests at all. Source that talks to Sparkle is compiled out via the
// NO_SPARKLE flag below.
let noSparkle = ProcessInfo.processInfo.environment["DORSO_NO_SPARKLE"] != nil

let package = Package(
    name: "Dorso",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "DorsoCore", targets: ["DorsoCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.10.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4")
    ],
    targets: [
        // Core logic library - testable, no main entry point
        .target(
            name: "DorsoCore",
            dependencies: noSparkle
                ? [.product(name: "ComposableArchitecture", package: "swift-composable-architecture")]
                : [
                    .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                    .product(name: "Sparkle", package: "Sparkle")
                ],
            path: "Sources",
            exclude: ["App", "Icons"],
            resources: [
                .process("Resources")
            ],
            swiftSettings: noSparkle ? [.define("NO_SPARKLE")] : [],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreMotion"),
                .linkedFramework("IOBluetooth")
            ]
        ),
        // Executable target
        .executableTarget(
            name: "Dorso",
            dependencies: ["DorsoCore"],
            path: "Sources/App"
        ),
        // Test target
        .testTarget(
            name: "DorsoTests",
            dependencies: [
                "DorsoCore",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture")
            ],
            path: "Tests"
        )
    ]
)
