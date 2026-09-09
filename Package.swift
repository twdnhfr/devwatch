// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DevWatch",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DevWatch", targets: ["DevWatch"])],
    targets: [
        .target(name: "DevWatchCore", resources: [.process("Resources")]),
        .executableTarget(name: "DevWatch", dependencies: ["DevWatchCore"]),
        .testTarget(name: "DevWatchCoreTests", dependencies: ["DevWatchCore"])
    ],
    swiftLanguageModes: [.v5]
)
