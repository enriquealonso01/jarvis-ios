import XCTest

/// Item 0 smoke: every v2 package in the plan's §5.1 module map must exist
/// with a parseable, well-formed Package.swift. This catches "builder added a
/// package dir but the manifest is broken/missing" before CI burns 6 minutes
/// of macOS time.
final class SkeletonLintTests: XCTestCase {
    /// Packages/ dirs required by V2-PLAN §5.1 + BuildSmokeTests itself.
    static let requiredPackages = [
        "JarvisKit", "Persistence", "FeaturesChat", "FeaturesProjects",
        "FeaturesVoice", "FeaturesRuns", "FeaturesCapture", "CallKit",
        "DesignSystem", "JarvisIntents", "BuildSmokeTests",
    ]

    /// Plan §5.1 module map — FeaturesProjects is listed in the plan but is a
    /// P3 (M3) item; tolerate its absence until M3, everything else must exist.
    static let deferredUntilM3: Set<String> = ["FeaturesProjects"]

    private func packagesRoot() -> URL {
        // Package.swift sets TEST cwd to the target's build dir; derive repo
        // root by walking up from #file to the dir containing "Packages".
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 {
            url.deleteLastPathComponent()
            if url.lastPathComponent == "Packages" { return url }
        }
        fatalError("Packages/ root not found above \(#filePath)")
    }

    func testEveryRequiredPackageHasValidManifest() throws {
        let root = packagesRoot()
        let deferred = Self.deferredUntilM3
        for name in Self.requiredPackages {
            let dir = root.appendingPathComponent(name)
            let manifest = dir.appendingPathComponent("Package.swift")
            let isDeferred = deferred.contains(name)
            guard FileManager.default.fileExists(atPath: manifest.path) else {
                // FeaturesProjects is the one §5.1 package deferred to M3 —
                // absence is fine in Item 0; every other package must exist.
                if !isDeferred {
                    XCTFail("Required v2 package missing manifest: Packages/\(name)/Package.swift")
                }
                continue
            }
            let src = try String(contentsOf: manifest, encoding: .utf8)
            XCTAssertTrue(src.contains("swift-tools-version"),
                          "\(name)/Package.swift missing swift-tools-version")
            XCTAssertTrue(src.contains("import PackageDescription"),
                          "\(name)/Package.swift missing `import PackageDescription`")
            XCTAssertTrue(src.contains("let package = Package("),
                          "\(name)/Package.swift missing package declaration")
            // Structural sanity: balanced braces (crude but catches truncation).
            XCTAssertEqual(src.filter { $0 == "{" }.count,
                           src.filter { $0 == "}" }.count,
                           "\(name)/Package.swift has unbalanced braces")
        }
    }

    func testNoPackageManifestUsesLegacySwiftToolsVersion() throws {
        // All v2 packages pin swift-tools-version:6.0 (Swift 6 strict mode per plan §5.1).
        let root = packagesRoot()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else {
            return XCTFail("cannot list Packages/")
        }
        for name in entries where !name.hasPrefix(".") {
            let manifest = root.appendingPathComponent("\(name)/Package.swift").path
            guard fm.fileExists(atPath: manifest),
                  let src = try? String(contentsOfFile: manifest, encoding: .utf8) else { continue }
            XCTAssertTrue(src.contains("// swift-tools-version:6.0"),
                          "\(name)/Package.swift must pin swift-tools-version:6.0 (found a different/missing pin)")
        }
    }
}
