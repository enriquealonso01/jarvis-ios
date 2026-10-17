// swift-tools-version:6.0
import PackageDescription

// CI smoke-test package (V2-PLAN Item 0 tester scope). This package contains
// ONLY test targets: it exists so one `swift test` run asserts the whole v2
// skeleton — every package's Package.swift is present and valid, JarvisKit's
// public API instantiates, and the Persistence migration scaffold runs on a
// fresh in-memory database. It is intentionally not a product dependency of
// the app; ios-test.yml runs it standalone.
let package = Package(
    name: "BuildSmokeTests",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [],
    dependencies: [
        .package(path: "../JarvisKit"),
        .package(path: "../Persistence"),
    ],
    targets: [
        // The skeleton-lint target reads Packages/*/Package.swift off disk and
        // parses it; pure Foundation, runs anywhere.
        .testTarget(
            name: "SkeletonLintTests",
            dependencies: [],
            path: "Tests/SkeletonLintTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "JarvisKitSmokeTests",
            dependencies: [.product(name: "JarvisKit", package: "JarvisKit")],
            path: "Tests/JarvisKitSmokeTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PersistenceSmokeTests",
            dependencies: [.product(name: "Persistence", package: "Persistence")],
            path: "Tests/PersistenceSmokeTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
