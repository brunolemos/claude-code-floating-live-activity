// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeLiveActivity",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "ClaudeLiveActivity", path: "Sources/App"),
        .executableTarget(name: "claude-status-hook", path: "Sources/Hook"),
    ]
)
