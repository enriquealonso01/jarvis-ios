import XCTest
import JarvisKit
import Persistence
@testable import FeaturesChat

/// Item 8 BUILDER smokes — the two M1 exit gates, driven headlessly through
/// the REAL production seams (no mirror seams: these exercise
/// `TranscriptLayoutEngine` + `TranscriptViewModel` + `PersistenceStore`):
///
///   1. 1k-message conversation renders/streams without unbounded memory —
///      windowed rendering: the merge+window output is bounded at
///      `TranscriptLayoutEngine.maxVisibleMessages` (200) no matter the
///      conversation size, and `renderRows` stays O(total) per pass.
///   2. Cold-launch restore shows the full transcript from the store — the
///      store's `streamRestoreState` path, pinned from the view-model layer:
///      a mid-stream `.streaming` row is re-seeded into the live overlay and
///      the transcript shows stored history + the partial, never a dup.
final class Item8TranscriptBuilderSmokeTests: XCTestCase {

    // MARK: - M1 gate 1: 1k messages, bounded render surface

    /// Windowed rendering: 1,000 stored rows + a live overlay merge into at
    /// most `maxVisibleMessages` display rows; the visible tail is the NEWEST
    /// content (window never shows stale head rows).
    func testOneThousandMessageConversationRendersBoundedWindow() async {
        let conv = UUID()
        var stored: [StoredMessage] = []
        stored.reserveCapacity(1_005)
        for i in 0..<1_000 {
            stored.append(StoredMessage(
                conversationID: conv,
                role: i.isMultiple(of: 2) ? .user : .assistant,
                content: "msg \(i)",
                status: .sent,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i))))
        }

        // Live overlay mid-stream on top of the 1k history.
        let live = [
            StreamMessageSnapshot(
                id: 7, state: .streaming, text: "streaming…", lastEventID: 42),
        ]
        let rows = TranscriptLayoutEngine.renderRows(stored: stored, live: live)
        XCTAssertEqual(rows.count, TranscriptLayoutEngine.maxVisibleMessages,
                       "render surface bounded at the window cap (M1 1k gate)")
        XCTAssertEqual(rows.last?.text, "streaming…",
                       "live overlay is the newest visible row")
        XCTAssertEqual(rows.first?.text, "msg \(1_000 - TranscriptLayoutEngine.maxVisibleMessages + 1)",
                       "window shows the newest tail, never the stale head")
        // No duplicates: ids stay unique across the merge.
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "no duplicate row ids")
    }

    /// Live overlay hands off to the store row without a dup or a gap:
    /// while the store's copy is mid-stream the overlay is fresher (store
    /// copy hidden); once the store's copy is terminal the overlay retires
    /// and the store row is authoritative (§3 stop: the pipeline froze +
    /// persisted the partial).
    func testLiveOverlayRetiresWhenStoreRowTurnsTerminal() {
        let conv = UUID()
        let msgID = UUID()

        // Phase 1: store row still .streaming (pipeline debounce in flight)
        // → overlay renders, stored copy hidden.
        var mid = StoredMessage(
            conversationID: conv,
            role: .assistant,
            content: "partial answer",
            status: .streaming,
            createdAt: Date(timeIntervalSince1970: 1_700_000_001))
        mid.id = msgID
        let live = [StreamMessageSnapshot(
            id: 3, state: .streaming, text: "partial answer", lastEventID: 9)]
        var rows = TranscriptLayoutEngine.renderRows(
            stored: [mid], live: live, liveMessageIDs: [3: msgID])
        XCTAssertEqual(rows.filter { $0.origin == .live }.count, 1,
                       "mid-stream: the overlay is the fresher render")
        XCTAssertEqual(rows.filter { $0.origin == .stored }.count, 0,
                       "mid-stream: the stale stored copy is hidden, not dup'd")

        // Phase 2: store row lands terminal → overlay retires, store row
        // is the single source of truth.
        mid.status = .sent
        rows = TranscriptLayoutEngine.renderRows(
            stored: [mid], live: live, liveMessageIDs: [3: msgID])
        XCTAssertEqual(rows.count, 1, "exactly one row — no dup, no gap")
        XCTAssertEqual(rows.first?.origin, .stored,
                       "store-authoritative once terminal")
    }

    // MARK: - M1 gate 2: cold-launch restore shows the full transcript

    /// Store path: a mid-stream row + history restores from
    /// `streamRestoreState` — snapshot found, resume pointer correct.
    func testColdLaunchRestoreSeedsMidStreamRowFromStore() async throws {
        let store = PersistenceStore()
        let conv = UUID()
        for i in 0..<20 {
            try await store.upsert(StoredMessage(
                conversationID: conv,
                role: i.isMultiple(of: 2) ? .user : .assistant,
                content: "history \(i)",
                status: .sent,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i))))
        }
        let mid = StoredMessage(
            conversationID: conv,
            role: .assistant,
            content: "partial streamed text",
            status: .streaming,
            lastEventID: 321,
            createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        await store.upsert(mid)

        let state = try await store.streamRestoreState(conversationID: conv)
        XCTAssertEqual(state.snapshot?.id, mid.id, "mid-stream row is the restore seed")
        XCTAssertEqual(state.snapshot?.content, "partial streamed text")
        XCTAssertEqual(state.resumeEventID, 321, "resume continues from the store pointer")

        // View-model layer: seed the overlay exactly as the client does.
        let vm = TranscriptViewModel(conversationID: conv, store: store, streamClient: nil)
        await vm.loadInitial()
        let userRows = vm.displayRows.filter { $0.isUser }
        XCTAssertEqual(userRows.count, 10, "full transcript visible from the store")
        let partial = vm.displayRows.last
        XCTAssertEqual(partial?.text, "partial streamed text",
                       "cold launch shows the persisted partial (M1 restore gate)")
        XCTAssertEqual(partial?.status, .streaming)
        vm.cancelTail()
    }

    /// Restore overlays the live tail without duplicating the seeded row:
    /// with the stream-id → UUID routing applied, the stored `.streaming`
    /// row is hidden and exactly one live block renders.
    func testRestoredOverlayDoesNotDuplicateSeededRow() {
        let conv = UUID()
        let midID = UUID()
        var stored: [StoredMessage] = []
        for i in 0..<30 {
            var m = StoredMessage(
                conversationID: conv,
                role: i.isMultiple(of: 2) ? .user : .assistant,
                content: "h\(i)",
                status: .sent,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)))
            m.id = UUID()
            stored.append(m)
        }
        var mid = StoredMessage(
            conversationID: conv,
            role: .assistant,
            content: "partial",
            status: .streaming,
            createdAt: Date(timeIntervalSince1970: 1_700_000_500))
        mid.id = midID

        let streamID = ChatStreamEngine.streamMessageID(forMessageUUID: midID)
        let live = [StreamMessageSnapshot(
            id: streamID, state: .streaming, text: "partial", lastEventID: 5)]
        let rows = TranscriptLayoutEngine.renderRows(
            stored: stored + [mid], live: live, liveMessageIDs: [streamID: midID])
        let partials = rows.filter { $0.text == "partial" }
        XCTAssertEqual(partials.count, 1,
                       "seeded row renders exactly once (overlay, not dup)")
        XCTAssertEqual(partials.first?.origin, .live)
    }

    // MARK: - §5 pin on the real engine (BUILDER side)

    func testEngineScrollDecisionsMatchUILaw() {
        XCTAssertFalse(TranscriptLayoutEngine.shouldAutoScroll(isAtBottom: false),
                       "never fight the user mid-stream (§5)")
        XCTAssertTrue(TranscriptLayoutEngine.shouldAutoScroll(isAtBottom: true),
                      "at bottom → follow the stream (§5)")
        XCTAssertEqual(TranscriptLayoutEngine.grownBottomBuffer(current: 0), 50,
                       accuracy: 0.01, "~50pt buffer (§5)")
        XCTAssertEqual(TranscriptLayoutEngine.grownBottomBuffer(current: 80), 80,
                       accuracy: 0.01, "buffer is monotonic — never shrunk (§5)")
    }
}
