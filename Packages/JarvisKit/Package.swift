// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "JarvisKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "JarvisKit", targets: ["JarvisKit"])],
    targets: [
        .target(
            name: "JarvisKit",
            // Item 2: SSE/stream fixture contract (contract.json + sample
            // event streams) ships as bundle resources so tests AND future UI
            // previews replay the exact same wire shapes (plan Risk-3).
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "JarvisKitTests", dependencies: ["JarvisKit"], swiftSettings: [.swiftLanguageMode(.v6)])
    ]
)
