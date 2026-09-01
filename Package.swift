// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BattCycle",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "BattCycleCore", targets: ["BattCycleCore"]),
        .executable(name: "BattCycle", targets: ["BattCycle"])
    ],
    targets: [
        .target(
            name: "BattCycleCore",
            path: "Sources/BattCycleCore",
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug)),
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "BattCycle",
            dependencies: ["BattCycleCore"],
            path: "Sources/BattCycle",
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug)),
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "BattCycleCoreTests",
            dependencies: ["BattCycleCore"],
            path: "Tests/BattCycleCoreTests"
        )
    ]
)
