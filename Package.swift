// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "grc-whisper",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "GRCWhisper",
            path: "Sources/GRCWhisper",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])]
        )
    ]
)
