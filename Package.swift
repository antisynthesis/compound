// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Compound",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
        .visionOS(.v26),
    ],
    products: [
        .library(name: "Compound", targets: ["Compound"]),
    ],
    targets: [
        .target(
            name: "Compound",
            path: "Sources/Compound"
        ),
        .testTarget(
            name: "CompoundTests",
            dependencies: ["Compound"],
            path: "Tests/CompoundTests"
        ),
    ]
)

// The end-to-end example at Examples/CompoundExample/main.swift is not part
// of the build graph because it uses the @Generable macro from
// FoundationModels, which requires the FoundationModelsMacros compiler
// plugin bundled only with full Xcode. To run it, open this package in
// Xcode 26 or add it as a separate target there.
