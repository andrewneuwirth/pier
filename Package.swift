// swift-tools-version:6.2
import PackageDescription
import Foundation

// A Kit checkout next to this folder wins (for working on both); otherwise the published Kit.
let localKit = Context.packageDirectory + "/../Kit"
let kit: Package.Dependency = FileManager.default.fileExists(atPath: localKit + "/Package.swift")
    ? .package(path: "../Kit")
    : .package(url: "https://github.com/newitools/kit.git", branch: "main")

let package = Package(
    name: "Pier",
    platforms: [.macOS(.v26)],
    dependencies: [kit],
    targets: [
        .executableTarget(
            name: "Pier",
            dependencies: [.product(name: "MacToolsKit", package: "kit")],
            path: "Sources/Pier",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
