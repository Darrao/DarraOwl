// swift-tools-version: 6.2
import PackageDescription

let shared: Target.Dependency = .product(name: "DarraOwlShared", package: "shared")

let package = Package(
    name: "DarraOwlMac",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "DarraOwlMacUI", targets: ["DarraOwlMacUI"]),
        .library(name: "DarraOwlHelperKit", targets: ["DarraOwlHelperKit"]),
        .library(name: "DarraOwlCLIKit", targets: ["DarraOwlCLIKit"]),
        // Core and live adapters, for tools/link-e2e.
        .library(name: "DarraOwlMacKit", targets: ["DarraOwlCore", "DarraOwlSystem"]),
        .executable(name: "DarraOwlHelper", targets: ["DarraOwlHelper"]),
        .executable(name: "DarraOwl", targets: ["DarraOwlMac"]),
        // Installed as `darraowl` by Xcode; this name avoids a clash with
        // "DarraOwl" on a case-insensitive disk.
        .executable(name: "DarraOwlCLI", targets: ["DarraOwlCLI"]),
    ],
    dependencies: [
        .package(path: "../shared"),
    ],
    targets: [
        // Pure logic. Never depends on DarraOwlSystem.
        .target(name: "DarraOwlCore", dependencies: [shared]),
        // Live adapters: pmset, IOKit. Never linked by a test target.
        .target(name: "DarraOwlSystem", dependencies: ["DarraOwlCore", shared]),
        .target(name: "DarraOwlXPC", dependencies: ["DarraOwlCore", shared]),
        .target(name: "DarraOwlHelperKit", dependencies: ["DarraOwlCore", "DarraOwlSystem", "DarraOwlXPC", shared]),
        .executableTarget(name: "DarraOwlHelper", dependencies: ["DarraOwlHelperKit"]),
        .target(name: "DarraOwlMacUI", dependencies: ["DarraOwlCore", "DarraOwlSystem", "DarraOwlXPC", shared]),
        .executableTarget(name: "DarraOwlMac", dependencies: ["DarraOwlMacUI"]),
        .target(name: "DarraOwlCLIKit", dependencies: ["DarraOwlCore", "DarraOwlXPC", shared]),
        .executableTarget(name: "DarraOwlCLI", dependencies: ["DarraOwlCLIKit"]),
        .testTarget(name: "DarraOwlCoreTests", dependencies: ["DarraOwlCore", shared]),
        .testTarget(name: "DarraOwlXPCTests", dependencies: ["DarraOwlXPC", "DarraOwlCore", shared]),
    ]
)
