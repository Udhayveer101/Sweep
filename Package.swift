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
        // YARA-X's C API (BSD-3-Clause). Resolved through pkg-config so the build does not
        // hard-code a Homebrew path; `make-app.sh` copies the dylib into the bundle so the
        // shipped app does not depend on Homebrew being installed.
        .systemLibrary(
            name: "CYaraX",
            path: "Sources/CYaraX",
            pkgConfig: "yara_x_capi",
            providers: [.brew(["yara-x"])]
        ),
        .target(
            name: "SweepCore",
            dependencies: ["CYaraX"],
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
