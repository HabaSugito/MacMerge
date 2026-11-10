// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacMerge",
    platforms: [.macOS(.v14)],
    targets: [
        // Diff engine with no UI dependencies, so it can be tested on its own.
        .target(name: "DiffCore"),
        .executableTarget(name: "MacMerge", dependencies: ["DiffCore"]),
        .testTarget(name: "DiffCoreTests", dependencies: ["DiffCore"]),
    ]
)
