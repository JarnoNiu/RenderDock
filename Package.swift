// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RenderDock",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "RenderDock",
            path: "Sources/RenderDock",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
