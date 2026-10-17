// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FeaturesSidebar",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "FeaturesSidebar", targets: ["FeaturesSidebar"])],
    dependencies: [
        // §5.1 rule: feature packages depend only on JarvisKit / Persistence /
        // DesignSystem — never on other feature packages.
        .package(path: "../JarvisKit"),
        .package(path: "../Persistence"),
        .package(path: "../DesignSystem"),
    ],
    targets: [
        .target(
            name: "FeaturesSidebar",
            dependencies: [
                .product(name: "JarvisKit", package: "JarvisKit"),
                .product(name: "Persistence", package: "Persistence"),
                .product(name: "DesignSystem", package: "DesignSystem"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FeaturesSidebarTests",
            dependencies: [
                .product(name: "JarvisKit", package: "JarvisKit"),
                .product(name: "Persistence", package: "Persistence"),
                .product(name: "DesignSystem", package: "DesignSystem"),
                "FeaturesSidebar",
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
