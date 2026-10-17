import XCTest

@testable import FeaturesCapture

final class FeaturesCaptureTests: XCTestCase {
    func testChunkBoundaries() {
        XCTAssertEqual(RecorderPolicy.chunkIndex(at: 0), 0)
        XCTAssertEqual(RecorderPolicy.chunkIndex(at: 299), 0)
        XCTAssertEqual(RecorderPolicy.chunkIndex(at: 300), 1) // 5-min rollover
        XCTAssertEqual(RecorderPolicy.chunkIndex(at: 2_400), 8)
        XCTAssertEqual(RecorderPolicy.chunkIndex(at: -5), 0) // clamp
    }

    func testRecordingDefaults() {
        let rec = Recording(title: "Standup")
        XCTAssertEqual(rec.durationSeconds, 0)
        XCTAssertEqual(rec.transcriptSegmentCount, 0)
    }
}
