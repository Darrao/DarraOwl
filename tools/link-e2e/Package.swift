// swift-tools-version: 6.2
// Manual end-to-end check of the direct link (not a test: it opens real
// loopback sockets). Run: swift run --package-path tools/link-e2e
import PackageDescription

let package = Package(
    name: "LinkE2E",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../../mac"),
        .package(path: "../../ios"),
        .package(path: "../../shared"),
    ],
    targets: [
        .executableTarget(name: "LinkE2E", dependencies: [
            .product(name: "DarraOwlMacKit", package: "mac"),
            .product(name: "DarraOwlPhoneKit", package: "ios"),
            .product(name: "DarraOwlShared", package: "shared"),
        ]),
    ]
)
