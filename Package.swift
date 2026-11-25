// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RenderDock",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything that finds jobs and reads the machine: no UI, usable on its own.
        .target(
            name: "RenderDockCore",
            path: "Sources/RenderDockCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // What the desktop widget shows and how it draws it. Its own small target, so that the widget (a sandboxed
        // extension) carries nothing else, and the app can draw the same face into a picture.
        .target(
            name: "RenderDockWidgetViews",
            path: "Sources/RenderDockWidgetViews",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The widget itself: an app extension, bundled into the app by scripts/build-app.sh. An extension's
        // process starts in the system's own entry point and not in a `main`.
        .executableTarget(
            name: "RenderDockWidget",
            dependencies: ["RenderDockWidgetViews"],
            path: "Sources/RenderDockWidget",
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        // The app: capsule, panel, menu-bar item.
        .executableTarget(
            name: "RenderDock",
            dependencies: ["RenderDockCore", "RenderDockWidgetViews"],
            path: "Sources/RenderDock",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The command line: `renderdock run -- <command>` and `renderdock status`. Built as renderdock-cli because
        // on a case-insensitive disk it cannot sit next to the app's own RenderDock binary; installed as `renderdock`.
        .executableTarget(
            name: "renderdock-cli",
            dependencies: ["RenderDockCore"],
            path: "Sources/renderdock-cli",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Self-contained checks for the core (`swift run rd-checks`). Plain executable so it runs with
        // the Command Line Tools alone, where XCTest and Swift Testing are not on the default search path.
        .executableTarget(
            name: "rd-checks",
            dependencies: ["RenderDockCore", "RenderDockWidgetViews"],
            path: "Tests/rd-checks",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
