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
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            // The dev machine's swiftc (6.3.1) is newer than whatever Xcode CI
            // builds with — a plain .swiftmodule only imports on an EXACT
            // compiler-version match. Library evolution emits a resilient
            // .swiftinterface instead, importable across compiler versions.
            swiftSettings: [.unsafeFlags(["-enable-library-evolution"])]
        )
    ]
)
