// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "HedgedRequestKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9)
    ],
    products: [
        .library(name: "HedgedRequestKit", targets: ["HedgedRequestKit"]),
        .executable(name: "HedgedRequestDemo", targets: ["HedgedRequestDemo"])
    ],
    targets: [
        .target(
            name: "HedgedRequestKit",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .executableTarget(
            name: "HedgedRequestDemo",
            dependencies: ["HedgedRequestKit"],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "HedgedRequestKitTests",
            dependencies: ["HedgedRequestKit"]
        )
    ]
)
