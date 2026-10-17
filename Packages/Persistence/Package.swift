// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Persistence",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "Persistence", targets: ["Persistence"])],
    targets: [
        .target(name: "Persistence", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence"], swiftSettings: [.swiftLanguageMode(.v6)])
    ]
)
