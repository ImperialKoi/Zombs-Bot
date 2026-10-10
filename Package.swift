// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZombsAssistant",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ZombsAssistant", targets: ["ZombsAssistant"]),
        .executable(name: "ZombsReplay", targets: ["ZombsReplay"]),
        .executable(name: "ZombsPerceive", targets: ["ZombsPerceive"]),
        .library(name: "AssistantCore", targets: ["AssistantCore"]),
        .library(name: "Perception", targets: ["Perception"])
    ],
    targets: [
        .target(name: "AssistantCore"),
        .target(name: "Perception", dependencies: ["AssistantCore"]),
        .executableTarget(name: "ZombsAssistant", dependencies: ["AssistantCore", "Perception"]),
        .executableTarget(name: "ZombsReplay", dependencies: ["AssistantCore"]),
        .executableTarget(name: "ZombsPerceive", dependencies: ["AssistantCore", "Perception"]),
        .testTarget(name: "AssistantCoreTests", dependencies: ["AssistantCore"]),
        .testTarget(name: "PerceptionTests", dependencies: ["Perception", "AssistantCore"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v5]
)
