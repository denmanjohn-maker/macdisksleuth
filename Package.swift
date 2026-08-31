// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "macdisksleuth",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DiskSleuthKit", targets: ["DiskSleuthKit"]),
        .executable(name: "disksleuth", targets: ["disksleuth"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .target(name: "DiskSleuthKit"),
        .executableTarget(
            name: "disksleuth",
            dependencies: [
                "DiskSleuthKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(name: "FixtureSupport", path: "Tests/FixtureSupport"),
        .testTarget(
            name: "DiskSleuthKitTests",
            dependencies: ["DiskSleuthKit", "FixtureSupport"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
