// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DeepSeekCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DeepSeekCore", targets: ["DeepSeekCore"])
    ],
    targets: [
        .target(
            name: "DeepSeekCore",
            path: "Sources/DeepSeekCore"
        ),
        .testTarget(
            name: "DeepSeekCoreTests",
            dependencies: ["DeepSeekCore"],
            path: "Tests/DeepSeekCoreTests"
        )
    ]
)
