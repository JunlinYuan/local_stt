// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalSTT",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LocalSTTCore", targets: ["LocalSTTCore"]),
    ],
    targets: [
        .target(
            name: "LocalSTTCore",
            path: "Sources/LocalSTTCore"
        ),
        .testTarget(
            name: "LocalSTTCoreTests",
            dependencies: ["LocalSTTCore"],
            path: "Tests/LocalSTTCoreTests"
        ),
    ]
)
