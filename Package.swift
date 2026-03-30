// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeLiveStatus",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "ClaudeLiveStatus", path: "Sources/App"),
        .executableTarget(name: "claude-status-hook", path: "Sources/Hook"),
    ]
)
