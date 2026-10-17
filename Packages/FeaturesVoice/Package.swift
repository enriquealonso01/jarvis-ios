// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FeaturesVoice",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "FeaturesVoice", targets: ["FeaturesVoice"])],
    targets: [
        .target(name: "FeaturesVoice", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "FeaturesVoiceTests", dependencies: ["FeaturesVoice"], swiftSettings: [.swiftLanguageMode(.v6)])
    ]
)
