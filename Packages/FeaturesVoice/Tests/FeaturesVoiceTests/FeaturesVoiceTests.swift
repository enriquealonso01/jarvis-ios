import XCTest

@testable import FeaturesVoice

final class FeaturesVoiceTests: XCTestCase {
    func testConnectDisconnect() {
        var s = VoiceSessionState()
        XCTAssertFalse(s.isConnected)
        s.connect()
        XCTAssertTrue(s.isConnected)
        s.toggleMute()
        XCTAssertTrue(s.isMuted)
        s.disconnect()
        XCTAssertFalse(s.isConnected)
        XCTAssertFalse(s.isMuted)
    }

    func testDefaultPresentationIsInChat() {
        // UI Law §7: default presentation = in-chat voice layer
        XCTAssertEqual(VoiceSessionState().presentation, .inChat)
    }
}
