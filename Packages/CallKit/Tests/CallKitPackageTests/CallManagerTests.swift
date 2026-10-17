import XCTest

@testable import CallKitPackage

final class CallKitPackageTests: XCTestCase {
    func testHappyPathEightStepMachine() {
        var s = CallState()
        XCTAssertEqual(s.phase, .idle)
        XCTAssertTrue(s.transition(to: .reported))
        XCTAssertTrue(s.transition(to: .answered))
        XCTAssertTrue(s.transition(to: .activated)) // audio only legal here
        XCTAssertTrue(s.transition(to: .deactivated))
        XCTAssertTrue(s.transition(to: .ended))
    }

    func testAudioStartBeforeActivateIsIllegal() {
        var s = CallState()
        XCTAssertTrue(s.transition(to: .reported))
        // capture before didActivate — the documented dead-mic cause — is rejected
        XCTAssertFalse(s.transition(to: .deactivated))
        XCTAssertEqual(s.phase, .reported)
        // can never jump straight idle -> activated
        var idle = CallState()
        XCTAssertFalse(idle.transition(to: .activated))
        XCTAssertEqual(idle.phase, .idle)
    }

    func testPhaseCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(CallPhase.activated)
        XCTAssertEqual(try JSONDecoder().decode(CallPhase.self, from: data), .activated)
    }
}
