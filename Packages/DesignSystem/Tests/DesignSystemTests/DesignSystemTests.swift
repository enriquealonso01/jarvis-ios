import XCTest

@testable import DesignSystem

final class DesignSystemTests: XCTestCase {
    func testBubbleConstantsMatchUILaw() {
        // UI Law §2: user bubble max ~85% width
        XCTAssertEqual(Tokens.Bubble.maxWidthFraction, 0.85)
        // UI Law §6: composer grows ~5–6 lines
        XCTAssertTrue((5...6).contains(Tokens.Composer.maxVisibleLines))
        // UI Law §6: >5k chars auto-converts to attachment chip
        XCTAssertEqual(Tokens.Composer.largePasteThreshold, 5_000)
        // UI Law §1: slide-over ~85% width
        XCTAssertEqual(Tokens.Sidebar.widthFraction, 0.85)
        // UI Law §5: ~50pt monotonic bottom buffer
        XCTAssertEqual(Tokens.Sidebar.scrollBottomBuffer, 50)
    }

    func testLargePasteBoundary() {
        XCTAssertFalse(Tokens.isLargePaste(5_000)) // exactly 5k stays text
        XCTAssertTrue(Tokens.isLargePaste(5_001))
        XCTAssertTrue(Tokens.isLargePaste(50_000))
        XCTAssertFalse(Tokens.isLargePaste(0))
    }

    // MARK: Item 3 sidebar tokens (UI Law §1)

    // MARK: Orbital Core v2 brand tokens (kit brand-tokens.json)

    func testBrandTokenHexMatchesKit() {
        XCTAssertEqual(String(format: "#%06X", Tokens.Brand.obsidianHex), "#070E14")
        XCTAssertEqual(String(format: "#%06X", Tokens.Brand.iceCoreHex), "#E6FFFF")
        XCTAssertEqual(String(format: "#%06X", Tokens.Brand.jarvisCyanHex), "#3FD6F5")
        XCTAssertEqual(String(format: "#%06X", Tokens.Brand.deepTealHex), "#0E7490")
        XCTAssertEqual(String(format: "#%06X", Tokens.Brand.metallicGrayHex), "#A7B3BD")
        XCTAssertEqual(String(format: "#%06X", Tokens.Brand.deepSurfaceHex), "#0C1B24")
        XCTAssertEqual(String(format: "#%06X", Tokens.Brand.surfaceBorderHex), "#213C4B")
    }

    // MARK: Orbital state periods (kit brand-tokens.json animations)

    func testOrbitalStatePeriodsMatchKit() {
        XCTAssertEqual(OrbitalState.idle.outerOrbitSeconds, 32)
        XCTAssertEqual(OrbitalState.idle.innerOrbitSeconds, 46)
        XCTAssertEqual(OrbitalState.listening.outerOrbitSeconds, 13)
        XCTAssertEqual(OrbitalState.listening.innerOrbitSeconds, 20)
        XCTAssertEqual(OrbitalState.thinking.outerOrbitSeconds, 7)
        XCTAssertEqual(OrbitalState.thinking.innerOrbitSeconds, 10)
        XCTAssertEqual(OrbitalState.responding.outerOrbitSeconds, 17)
        XCTAssertEqual(OrbitalState.responding.innerOrbitSeconds, 21)
        // Core effect periods: idle breath 5.5 / listening ripple 1.7 /
        // thinking scan 1.6 / responding pulse 1.35 (kit tokens).
        XCTAssertEqual(OrbitalState.idle.coreEffectSeconds, 5.5)
        XCTAssertEqual(OrbitalState.listening.coreEffectSeconds, 1.7)
        XCTAssertEqual(OrbitalState.thinking.coreEffectSeconds, 1.6)
        XCTAssertEqual(OrbitalState.responding.coreEffectSeconds, 1.35)
    }

    func testOrbitalStateRawValues() {
        // Raw values are stable API for callers mapping real events.
        XCTAssertEqual(OrbitalState(rawValue: "idle"), .idle)
        XCTAssertEqual(OrbitalState(rawValue: "listening"), .listening)
        XCTAssertEqual(OrbitalState(rawValue: "thinking"), .thinking)
        XCTAssertEqual(OrbitalState(rawValue: "responding"), .responding)
        XCTAssertNil(OrbitalState(rawValue: "fake-status"))
    }

    func testSidebarTokensMatchUILaw() {
        // Slide-over is ~85% width per UI Law §1 (research/11: 80–85%).
        XCTAssertTrue((0.80...0.85).contains(Tokens.Sidebar.widthFraction))
        // Recents pagination page size is sane.
        XCTAssertTrue(Tokens.Sidebar.recentsPageSize >= 8,
                      "research/11 §1.6: up to 8 recents visible; page ≥ 8")
        // Store keys are namespaced and unique.
        let keys = [Tokens.Sidebar.Keys.sidebarOpen,
                    Tokens.Sidebar.Keys.lastSelection,
                    Tokens.Sidebar.Keys.projectsExpanded]
        XCTAssertEqual(Set(keys).count, keys.count)
    }
}
