// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DarraOwlShared",
    platforms: [.macOS(.v26), .iOS(.v26), .watchOS(.v26)],
    products: [
        .library(name: "DarraOwlShared", targets: ["DarraOwlShared"]),
    ],
    targets: [
        .target(name: "DarraOwlShared"),
        .testTarget(name: "DarraOwlSharedTests", dependencies: ["DarraOwlShared"]),
    ]
)
