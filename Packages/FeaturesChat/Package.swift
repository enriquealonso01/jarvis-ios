// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FeaturesChat",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "FeaturesChat", targets: ["FeaturesChat"])],
    dependencies: [
        // AgentEvent + APIClient (kit is the shared dependency hub, plan §5.1).
        .package(path: "../JarvisKit"),
        // Stream writes land in the GRDB store (Item 2 persistence integration).
        .package(path: "../Persistence"),
    ],
    targets: [
        .target(
            name: "FeaturesChat",
            dependencies: [
                .product(name: "JarvisKit", package: "JarvisKit"),
                .product(name: "Persistence", package: "Persistence"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FeaturesChatTests",
            dependencies: [
                .product(name: "JarvisKit", package: "JarvisKit"),
                .product(name: "Persistence", package: "Persistence"),
                "FeaturesChat",
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
