// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DevWatch",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DevWatch", targets: ["DevWatch"])],
    targets: [
        .target(name: "DevWatchCore"),
        .executableTarget(name: "DevWatch", dependencies: ["DevWatchCore"]),
        .testTarget(name: "DevWatchCoreTests", dependencies: ["DevWatchCore"])
    ],
    swiftLanguageModes: [.v5]
)
