// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TuneSync",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TuneSync", targets: ["TuneSync"]),
        .library(name: "TuneSyncCore", targets: ["TuneSyncCore"]),
    ],
    targets: [
        .target(
            name: "TuneSyncCore"
        ),
        .executableTarget(
            name: "TuneSync",
            dependencies: ["TuneSyncCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "TuneSyncCoreTests",
            dependencies: ["TuneSyncCore"]
        ),
    ]
)
