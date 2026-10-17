// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CallKitPackage",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "CallKitPackage", targets: ["CallKitPackage"])],
    targets: [
        // iOS-only: real CallKit/PushKit/WebRTC glue lands in M2 per plan §5.4.
        .target(name: "CallKitPackage", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "CallKitPackageTests", dependencies: ["CallKitPackage"], swiftSettings: [.swiftLanguageMode(.v6)])
    ]
)
