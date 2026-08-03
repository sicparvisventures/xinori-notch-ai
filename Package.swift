// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NotchAI",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "NotchAI",
            path: "Sources/NotchAI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
