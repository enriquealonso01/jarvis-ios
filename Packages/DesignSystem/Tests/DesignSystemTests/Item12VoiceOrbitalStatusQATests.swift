import XCTest

import DesignSystem

/// Item 12 BUILDER QA — the real-event orbital binding surface.
///
/// UI Law §7 + kit law: the orbital is a pure function of REAL voice/call
/// events. These pins freeze (a) the state → sizing/a11y token contract of
/// the status surface and (b) that the wrapper carries exactly the four kit
/// states — a fabricated fifth state or a magic-number resize cannot land
/// silently.
final class Item12VoiceOrbitalStatusQATests: XCTestCase {

    func testStatusViewConstructsForEveryKitState() {
        for state in OrbitalState.allCases {
            let view = VoiceOrbitalStatusView(state: state)
            XCTAssertEqual(view.state, state, "wrapper passes the real state through untouched")
        }
    }

    /// The status surface sizes from Tokens.Voice — no magic numbers in the
    /// view; the token stays pinned here.
    func testStatusTokensAreThePinnedValues() {
        XCTAssertEqual(Tokens.Voice.statusOrbitalSize, 96)
        XCTAssertEqual(Tokens.Voice.pillHeight, 44, "a11y minimum tap target")
        XCTAssertEqual(Tokens.Voice.pillCornerRadius, 20)
        XCTAssertEqual(Tokens.Voice.pillHorizontalInset, 16)
    }

    /// All four kit states remain the entire reachable domain — the wrapper
    /// cannot invent a state the kit doesn't render (exhaustive switch in
    /// OrbitalCoreView makes a new case a compile error upstream; this pins
    /// the count from this side too).
    func testWrapperDomainIsExactlyTheFourKitStates() {
        XCTAssertEqual(OrbitalState.allCases.count, 4)
        for state in OrbitalState.allCases {
            // Constructing for every state is the compile-time proof; the
            // equality re-pin documents intent.
            XCTAssertEqual(VoiceOrbitalStatusView(state: state).state, state)
        }
    }
}
