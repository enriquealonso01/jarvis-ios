// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "JarvisKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "JarvisKit", targets: ["JarvisKit"])],
    targets: [
        .target(name: "JarvisKit", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "JarvisKitTests", dependencies: ["JarvisKit"], swiftSettings: [.swiftLanguageMode(.v6)])
    ]
)
