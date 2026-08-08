// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ZhCnToTw",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ZhCnToTw",
            path: "Sources/ZhCnToTw"
        )
    ]
)
