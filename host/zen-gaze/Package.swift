// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ZenGaze",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "ZenGaze", path: "Sources/ZenGaze")
    ]
)
