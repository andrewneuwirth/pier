// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Tuck",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "../Kit")],
    targets: [
        .executableTarget(
            name: "Tuck",
            dependencies: [.product(name: "MacToolsKit", package: "Kit")],
            path: "Sources/Tuck",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
