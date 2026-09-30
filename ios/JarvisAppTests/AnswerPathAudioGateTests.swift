
import XCTest
@testable import JarvisApp

/// Round-2 bug B regression pins: the push-answer path must not build the
/// WebRTC audio unit against an unconfigured CallKit audio session (the
/// category re-assert after the unit starts killed BOTH playout and capture
/// — gateway spoke, phone silent, builds 60-65).
final class AnswerPathAudioGateTests: XCTestCase {

    func testIsAudioSessionConfiguredFlagLifecycle() {
        // Fresh state: not configured.
        WebRTCClient.deactivateAudioSession(.sharedInstance())
        XCTAssertFalse(WebRTCClient.isAudioSessionConfigured)
        // didActivate configures → flag true → the answer-path gate passes.
        WebRTCClient.activateAudioSessionForTesting(.sharedInstance())
        XCTAssertTrue(WebRTCClient.isAudioSessionConfigured,
                      "activateAudioSession must arm isAudioSessionConfigured — the answer path waits on this before connecting")
        // didDeactivate clears it for the next call.
        WebRTCClient.deactivateAudioSession(.sharedInstance())
        XCTAssertFalse(WebRTCClient.isAudioSessionConfigured)
    }
}
