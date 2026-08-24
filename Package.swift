// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Loomup",
    platforms: [
        .iOS(.v16),
        .macOS(.v12),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(name: "Loomup", targets: ["Loomup"]),
        .library(name: "LoomupAppIntegrity", targets: ["LoomupAppIntegrity"]),
    ],
    targets: [
        .target(name: "Loomup", path: "swift/Sources/Loomup"),
        .target(
            name: "LoomupAppIntegrity",
            dependencies: ["Loomup"],
            path: "swift/Sources/LoomupAppIntegrity"
        ),
        .testTarget(
            name: "LoomupTests",
            dependencies: ["Loomup", "LoomupAppIntegrity"],
            path: "swift/Tests/LoomupTests"
        ),
    ]
)
