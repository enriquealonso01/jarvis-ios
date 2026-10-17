// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "JarvisKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "JarvisKit", targets: ["JarvisKit"])],
    dependencies: [
        // postMessage returns the OutboxPayload the caller enqueues when
        // offline (Item 2 offline-first, feature #4).
        .package(path: "../Persistence"),
    ],
    targets: [
        .target(
            name: "JarvisKit",
            dependencies: [
                .product(name: "Persistence", package: "Persistence"),
            ],
            // Item 2: SSE/stream fixture contract (contract.json + sample
            // event streams) ships as bundle resources so tests AND future UI
            // previews replay the exact same wire shapes (plan Risk-3).
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "JarvisKitTests", dependencies: ["JarvisKit"], swiftSettings: [.swiftLanguageMode(.v6)])
    ]
)
