// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VirtualDisplay",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "VirtualDisplay", path: "Sources/VirtualDisplay")
    ]
)
