// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Persistence",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "Persistence", targets: ["Persistence"])],
    dependencies: [
        // GRDB 7 (V2-PLAN §5.2: GRDB, not SwiftData).
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.3.0"),
    ],
    targets: [
        .target(
            name: "Persistence",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PersistenceTests",
            dependencies: ["Persistence"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
