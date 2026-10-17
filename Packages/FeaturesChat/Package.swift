// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FeaturesChat",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "FeaturesChat", targets: ["FeaturesChat"])],
    targets: [
        .target(name: "FeaturesChat", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "FeaturesChatTests", dependencies: ["FeaturesChat"], swiftSettings: [.swiftLanguageMode(.v6)])
    ]
)
