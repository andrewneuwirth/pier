// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Tuck",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Tuck",
            path: "Sources/Tuck",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
