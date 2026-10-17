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
}
