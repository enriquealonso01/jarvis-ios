import XCTest

@testable import Persistence

/// Item 12 BUILDER — the voice-layer write contract on the REAL store:
/// `addTranscriptSegment` is an UPSERT-BY-ID seam. The Item-12 seed suite
/// pins it behaviorally; this file pins the adjacent edges (fresh-append
/// still returns the row; FTS de-indexes replaced text) without touching
/// the tester's file.
final class Item12TranscriptUpsertTests: XCTestCase {

    private func tempDBPath() -> String {
        let dir = NSTemporaryDirectory() + "item12-upsert-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/store.sqlite"
    }

    private static let stamp = Date(timeIntervalSince1970: 1_760_000_000)

    private func makeRecording(_ store: PersistenceStore, _ label: String) async -> StoredRecording {
        let recording = StoredRecording(
            filePath: "recordings/\(label).m4a", duration: 5.0, updatedAt: Self.stamp)
        _ = await store.upsert(recording)
        return recording
    }

    /// Fresh append stays an insert: distinct ids are distinct rows, and the
    /// API returns the persisted row (the voice layer reads back what it wrote).
    func testFreshAppendInsertsDistinctRowsAndReturnsRow() async throws {
        let store = try PersistenceStore(path: tempDBPath())
        let recording = await makeRecording(store, "append")

        let a = await store.addTranscriptSegment(StoredTranscriptSegment(
            recordingID: recording.id, speaker: "user", text: "first words",
            createdAt: Self.stamp, updatedAt: Self.stamp))
        let b = await store.addTranscriptSegment(StoredTranscriptSegment(
            recordingID: recording.id, speaker: "assistant", text: "second words",
            createdAt: Self.stamp, updatedAt: Self.stamp))

        XCTAssertNotNil(a, "insert of a new id must return the row")
        XCTAssertNotNil(b)
        XCTAssertNotEqual(a?.id, b?.id)
        let rows = await store.transcriptSegments(recordingID: recording.id)
        XCTAssertEqual(rows.count, 2, "distinct ids = distinct rows")
    }

    /// Same-id write replaces the row AND retires the partial text from FTS
    /// (the synchronize trigger follows the update, so the old words must
    /// stop matching — a lingering copy is the two-tier contract's no-dup
    /// violation).
    func testSameIDWriteReplacesAndRetiresPartialFromFTS() async throws {
        let store = try PersistenceStore(path: tempDBPath())
        let recording = await makeRecording(store, "replace")

        let utterance = UUID()
        var partial = StoredTranscriptSegment(
            recordingID: recording.id, speaker: "user", text: "remi",
            createdAt: Self.stamp, updatedAt: Self.stamp)
        partial.id = utterance
        _ = await store.addTranscriptSegment(partial)

        var final = StoredTranscriptSegment(
            recordingID: recording.id, speaker: "user",
            text: "remind Jess to water the plants",
            createdAt: Self.stamp, updatedAt: Self.stamp)
        final.id = utterance // same id = same utterance, final state
        let replaced = await store.addTranscriptSegment(final)

        XCTAssertEqual(replaced?.id, utterance, "upsert returns the surviving row")
        let rows = await store.transcriptSegments(recordingID: recording.id)
        XCTAssertEqual(rows.count, 1, "same id never leaves two rows")
        XCTAssertEqual(rows.first?.text, "remind Jess to water the plants")

        // Final words searchable …
        let hit = try await store.searchTranscriptSegments(matching: "water")
        XCTAssertEqual(hit.map(\.id), [utterance])
        // … and the replaced partial text de-indexed.
        let phantom = try await store.searchTranscriptSegments(matching: "remi")
        // "remi" is a prefix of the final text's words in FTS5 default
        // tokenization? No: default FTS5 MATCH "remi" matches whole tokens
        // only — the final text's tokens are remind/jess/water/the/plants,
        // none of which is "remi". The partial row is gone, so zero hits.
        XCTAssertTrue(phantom.isEmpty, "replaced partial text must be de-indexed from FTS")
    }
}
