// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dobby",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "DobbyCore"),
        .executableTarget(name: "Dobby", dependencies: ["DobbyCore"]),
        .executableTarget(name: "DobbyHelper", dependencies: ["DobbyCore"]),
        // The live helper tests launch the DobbyHelper binary that `swift test` builds alongside.
        .testTarget(name: "DobbyCoreTests", dependencies: ["DobbyCore"]),
    ]
)
