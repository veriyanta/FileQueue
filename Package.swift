// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FileQueue",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FileQueueCore", targets: ["FileQueueCore"]),
        .executable(name: "FileQueue", targets: ["FileQueue"]),
    ],
    targets: [
        .target(name: "FileQueueCore"),
        .executableTarget(name: "FileQueue", dependencies: ["FileQueueCore"]),
        .testTarget(name: "FileQueueCoreTests", dependencies: ["FileQueueCore"]),
    ]
)
