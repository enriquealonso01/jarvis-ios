// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "JarvisIntents",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "JarvisIntents", targets: ["JarvisIntents"])],
    targets: [
        // AppIntents/AppShortcutsProvider wiring lands in M4 (features #41/#42/#44).
        // Stub keeps pure deep-link routing logic testable without AppIntents.
        .target(name: "JarvisIntents", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "JarvisIntentsTests", dependencies: ["JarvisIntents"], swiftSettings: [.swiftLanguageMode(.v6)])
    ]
)
