// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VirtualDisplay",
    platforms: [.macOS(.v14)],
    targets: [
        // Vendored Lua 5.4, the plugin language. See Sources/CLua/README.md.
        .target(name: "CLua",
                path: "Sources/CLua",
                exclude: ["README.md", "README.lua"],
                cSettings: [.headerSearchPath("include"), .define("LUA_USE_MACOSX")]),
        // The app itself. Kept as a library so the pure logic in it can be unit tested;
        // an executable target cannot be imported by a test target.
        .target(name: "VirtualDisplayCore", dependencies: ["CLua"], path: "Sources/VirtualDisplayCore"),
        .executableTarget(name: "VirtualDisplay",
                          dependencies: ["VirtualDisplayCore"],
                          path: "Sources/VirtualDisplay"),
        .testTarget(name: "VirtualDisplayCoreTests", dependencies: ["VirtualDisplayCore"]),
    ]
)
