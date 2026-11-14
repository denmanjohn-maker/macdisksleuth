// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "macdisksleuth",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MacDiskSleuthKit", targets: ["MacDiskSleuthKit"]),
        .executable(name: "macdisksleuth", targets: ["macdisksleuth"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .target(name: "MacDiskSleuthKit"),
        .executableTarget(
            name: "macdisksleuth",
            dependencies: [
                "MacDiskSleuthKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(name: "FixtureSupport", path: "Tests/FixtureSupport"),
        .testTarget(
            name: "MacDiskSleuthKitTests",
            dependencies: ["MacDiskSleuthKit", "FixtureSupport"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
