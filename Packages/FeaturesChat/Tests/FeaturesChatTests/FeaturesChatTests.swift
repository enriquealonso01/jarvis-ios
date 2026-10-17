import XCTest

@testable import FeaturesChat

final class FeaturesChatTests: XCTestCase {
    func testStreamCommitCoalescing() {
        var state = StreamState()
        state.begin()
        state.append(token: "Hel")
        state.append(token: "lo")
        XCTAssertEqual(state.displayText, "Hello")
        XCTAssertEqual(state.committedText, "")
        state.commitPending()
        XCTAssertEqual(state.committedText, "Hello")
        XCTAssertEqual(state.pendingText, "")
    }

    func testStopKeepsCommittedText() {
        var state = StreamState()
        state.begin()
        state.append(token: "partial ")
        state.stop()
        XCTAssertFalse(state.isStreaming)
        XCTAssertEqual(state.committedText, "partial ")
        // appends after stop are ignored
        state.append(token: "more")
        XCTAssertEqual(state.displayText, "partial ")
    }
}
