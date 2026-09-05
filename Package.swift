// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ServerPulse",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ServerPulse", path: "Sources/ServerPulse")
    ]
)
