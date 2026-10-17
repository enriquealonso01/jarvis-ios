// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FeaturesRuns",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "FeaturesRuns", targets: ["FeaturesRuns"])],
    targets: [
        .target(name: "FeaturesRuns", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "FeaturesRunsTests", dependencies: ["FeaturesRuns"], swiftSettings: [.swiftLanguageMode(.v6)])
    ]
)
