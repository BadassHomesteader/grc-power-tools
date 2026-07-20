// swift-tools-version:5.9
// This package is built ONLY in CI (see .github/workflows/build-fluidaudio-artifact.yml),
// never on the dev machine — swiftpm is broken there (see bundle.sh). The static libraries
// + swiftmodule it produces get harvested and linked directly into the main swiftc build.
import PackageDescription

let package = Package(
    name: "PowerToolsASRBridge",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PowerToolsASRBridge", type: .static, targets: ["PowerToolsASRBridge"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4")
    ],
    targets: [
        .target(
            name: "PowerToolsASRBridge",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        )
    ]
)
