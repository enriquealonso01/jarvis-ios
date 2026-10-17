// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FeaturesCapture",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "FeaturesCapture", targets: ["FeaturesCapture"])],
    targets: [
        .target(name: "FeaturesCapture", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "FeaturesCaptureTests", dependencies: ["FeaturesCapture"], swiftSettings: [.swiftLanguageMode(.v6)])
    ]
)
