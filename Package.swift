// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sweep",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SweepCore", targets: ["SweepCore"]),
        .executable(name: "SweepApp", targets: ["SweepApp"]),
        .executable(name: "MakeIcon", targets: ["MakeIcon"]),
    ],
    targets: [
        .target(
            name: "SweepCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MakeIcon",
            dependencies: ["SweepCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "SweepApp",
            dependencies: ["SweepCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SweepCoreTests",
            dependencies: ["SweepCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
