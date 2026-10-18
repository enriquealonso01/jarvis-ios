import XCTest

import DesignSystem

/// Item 12 TESTER QA — OrbitalCoreView state mapping (UI Law §7 + kit spec
/// "states must be driven by REAL events — never fabricated timers").
///
/// The pure-logic half of the contract: `OrbitalState` exposes exactly the
/// four kit states, and each state's animation periods are real token values
/// (NOT fabricated timers) with a fixed semantic ordering — thinking is the
/// most urgent (scan), idle the calmest (breath). The view itself is SwiftUI
/// and exercises on the xcodebuild lane; this suite pins the data the view
/// renders from, so a state-mapping change in Item 12 wiring cannot silently
/// desync the orbital from real call/phase state.
final class Item12OrbitalStateQATests: XCTestCase {

    func testExactlyTheFourKitStatesExist() {
        XCTAssertEqual(Set(OrbitalState.allCases.map(\.rawValue)),
                       ["idle", "listening", "thinking", "responding"],
                       "OrbitalState is the four-state kit contract — no extra/fabricated states")
        XCTAssertEqual(OrbitalState.allCases.count, 4)
    }

    /// Semantic urgency ordering against the committed kit tokens
    /// (Brand.swift): the more "active" the agent, the FASTER the orbit —
    /// i.e. the period SHRINKS. thinking (7s) < listening (13s) <
    /// responding (17s) < idle (32s, the calm breath).
    func testOuterOrbitUrgencyOrdering() {
        XCTAssertLessThan(OrbitalState.thinking.outerOrbitSeconds, OrbitalState.listening.outerOrbitSeconds)
        XCTAssertLessThan(OrbitalState.listening.outerOrbitSeconds, OrbitalState.responding.outerOrbitSeconds)
        XCTAssertLessThan(OrbitalState.responding.outerOrbitSeconds, OrbitalState.idle.outerOrbitSeconds,
                          "idle is the calmest state — the slowest orbit")
    }

    func testInnerOrbitCounterRotatesSlowerThanOuter() {
        for state in OrbitalState.allCases {
            XCTAssertGreaterThan(state.innerOrbitSeconds, state.outerOrbitSeconds,
                                 "\(state): inner track counter-rotates slower than outer")
            XCTAssertGreaterThan(state.coreEffectSeconds, 0, "\(state): core effect period is a real token")
        }
        // Most urgent core effect belongs to responding (pulse) / thinking
        // (scan); idle breathing is the slowest.
        XCTAssertLessThan(OrbitalState.responding.coreEffectSeconds, OrbitalState.idle.coreEffectSeconds)
        XCTAssertLessThan(OrbitalState.thinking.coreEffectSeconds, OrbitalState.idle.coreEffectSeconds)
    }

    /// Raw values are the persistence/telemetry keys — they must stay stable
    /// (a rename would orphan stored widget snapshots / logs).
    func testRawValuesAreStableKeys() {
        XCTAssertEqual(OrbitalState.idle.rawValue, "idle")
        XCTAssertEqual(OrbitalState.listening.rawValue, "listening")
        XCTAssertEqual(OrbitalState.thinking.rawValue, "thinking")
        XCTAssertEqual(OrbitalState.responding.rawValue, "responding")
    }

    /// OrbitalCoreView is constructible off-screen with every state (the
    /// xcodebuild lane exercises drawing; this pins the public init surface).
    func testOrbitalCoreViewConstructsForEveryState() {
        for state in OrbitalState.allCases {
            let view = OrbitalCoreView(state: state, isStatic: true)
            XCTAssertEqual(view.state, state)
            XCTAssertTrue(view.isStatic)
        }
        XCTAssertEqual(OrbitalCoreView(state: .idle, isStatic: true).state, .idle)
    }
}
