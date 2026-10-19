// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "razerctl",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "razerctl", path: "Sources/razerctl")
    ]
)
