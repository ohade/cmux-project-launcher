// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CmuxProjectLauncher",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CmuxProjectLauncherCore", targets: ["CmuxProjectLauncherCore"]),
        .executable(name: "cmux-project-launcher", targets: ["CmuxProjectLauncherApp"]),
    ],
    targets: [
        .target(
            name: "CmuxProjectLauncherCore",
            path: "Sources/CmuxProjectLauncherCore"
        ),
        .executableTarget(
            name: "CmuxProjectLauncherApp",
            dependencies: ["CmuxProjectLauncherCore"],
            path: "Sources/CmuxProjectLauncherApp"
        ),
        .testTarget(
            name: "CmuxProjectLauncherCoreTests",
            dependencies: ["CmuxProjectLauncherCore"],
            path: "Tests/CmuxProjectLauncherCoreTests"
        ),
    ]
)
