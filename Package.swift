// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Pier",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "../Kit")],
    targets: [
        .executableTarget(
            name: "Pier",
            dependencies: [.product(name: "MacToolsKit", package: "Kit")],
            path: "Sources/Pier",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
