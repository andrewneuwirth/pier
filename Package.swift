// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "UsageRings",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "UsageRings", path: "Sources/UsageRings")
    ]
)
