// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FeaturesVoice",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "FeaturesVoice", targets: ["FeaturesVoice"])],
    dependencies: [
        // Item 12: OrbitalState (kit four-state contract) — the voice layer
        // maps REAL engine events onto it (never fabricated timers).
        .package(path: "../DesignSystem"),
        // Item 12: transcript persistence rides the verified Item-1 upsert
        // path (addTranscriptSegment upsert-by-id; final replaces partial).
        .package(path: "../Persistence"),
    ],
    targets: [
        .target(
            name: "FeaturesVoice",
            dependencies: [
                .product(name: "DesignSystem", package: "DesignSystem"),
                .product(name: "Persistence", package: "Persistence"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(
            name: "FeaturesVoiceTests",
            dependencies: [
                .product(name: "DesignSystem", package: "DesignSystem"),
                .product(name: "Persistence", package: "Persistence"),
                "FeaturesVoice",
            ],
            swiftSettings: [.swiftLanguageMode(.v6)])
    ]
)
