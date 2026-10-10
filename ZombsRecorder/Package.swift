// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZombsRecorder",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ZombsRecorder", targets: ["ZombsRecorder"]),
        .executable(name: "zombs-extract", targets: ["ZombsExtract"]),
        .library(name: "RecorderCore", targets: ["RecorderCore"])
    ],
    targets: [
        .target(name: "RecorderCore"),
        .executableTarget(name: "ZombsRecorder", dependencies: ["RecorderCore"]),
        .executableTarget(name: "ZombsExtract", dependencies: ["RecorderCore"]),
        .testTarget(name: "RecorderCoreTests", dependencies: ["RecorderCore"])
    ],
    swiftLanguageModes: [.v5]
)
