// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QuickAI",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "QuickAI",
            path: "Sources/QuickAI",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)
