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
