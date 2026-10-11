// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DarraOwlPhone",
    // macOS too, so `swift test` runs the logic on the Mac.
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "DarraOwlPhoneKit", targets: ["DarraOwlPhoneKit"]),
    ],
    dependencies: [
        .package(path: "../shared"),
    ],
    targets: [
        .target(name: "DarraOwlPhoneKit", dependencies: [.product(name: "DarraOwlShared", package: "shared")]),
        .testTarget(name: "DarraOwlPhoneKitTests", dependencies: ["DarraOwlPhoneKit", .product(name: "DarraOwlShared", package: "shared")]),
    ]
)
