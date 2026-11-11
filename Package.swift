// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacMerge",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        // Diff engine with no UI dependencies.
        .target(name: "DiffCore"),
        // The app's windows, controllers and commands.
        .target(name: "MacMergeUI", dependencies: ["DiffCore"]),
        // A thin executable that starts the app.
        .executableTarget(name: "MacMerge", dependencies: ["MacMergeUI"]),
        .testTarget(name: "DiffCoreTests", dependencies: ["DiffCore"]),
        .testTarget(name: "MacMergeUITests", dependencies: ["MacMergeUI", "DiffCore"]),
    ]
)
