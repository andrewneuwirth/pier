// swift-tools-version:6.2
import PackageDescription
import Foundation

// A Kit checkout next to this folder wins (for working on both); otherwise the published Kit.
let localKit = Context.packageDirectory + "/../Kit"
let useLocal = FileManager.default.fileExists(atPath: localKit + "/Package.swift")
let kit: Package.Dependency = useLocal
    ? .package(path: "../Kit")
    : .package(url: "https://github.com/andrewneuwirth/mac-tools-kit.git", branch: "main")
let kitPackage = useLocal ? "Kit" : "mac-tools-kit"   // SwiftPM names it after the folder or the URL

let package = Package(
    name: "Pier",
    platforms: [.macOS(.v26)],
    dependencies: [kit],
    targets: [
        .executableTarget(
            name: "Pier",
            dependencies: [.product(name: "MacToolsKit", package: kitPackage)],
            path: "Sources/Pier",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
