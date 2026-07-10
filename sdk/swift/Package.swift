// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "Litebase",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
    ],
    products: [
        .library(name: "Litebase", targets: ["Litebase"]),
    ],
    targets: [
        .target(name: "Litebase"),
        .testTarget(
            name: "LitebaseTests",
            dependencies: ["Litebase"]
        ),
    ]
)
