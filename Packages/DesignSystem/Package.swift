// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DesignSystem",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "DesignSystem", targets: ["DesignSystem"])],
    targets: [
        .target(name: "DesignSystem", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"], swiftSettings: [.swiftLanguageMode(.v6)])
    ]
)
