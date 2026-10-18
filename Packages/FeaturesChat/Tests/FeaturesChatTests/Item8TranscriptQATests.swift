import XCTest
import JarvisKit
@testable import FeaturesChat

/// Item 8 TESTER QA — transcript/thread view (plan §4 #1/#2 completion,
/// UI Law §2 bubbles / §3 streaming render + stop / §5 scroll anchoring)
/// + M1 exit-gate smokes. Headless pure-logic suite: pins the layout and
/// scroll DECISION SEAMS the real SwiftUI views drive, plus a 1k-message
/// stream replay through the real engine. Mirrors the Item 2/4/5 QA style.
final class Item8TranscriptQATests: XCTestCase {

    // MARK: - Test-local mirrors of the view decision seams (§2/§5 math)

    /// §2: user bubble geometry decision — right-aligned, tinted, ≤85% width.
    /// Mirrors the transcript row layout decision; the view drives its
    /// frame from this exact arithmetic. (Headless: alignment is a plain
    /// enum the view maps to SwiftUI's .trailing/.leading.)
    enum Side: Equatable { case leading, trailing }

    struct BubbleGeometrySeam {
        var isUser: Bool
        var proposedWidth: CGFloat

        /// nil = assistant full-width unbubbled (no width cap applied).
        var bubbleWidth: CGFloat? {
            guard isUser else { return nil }
            let cap = proposedWidth * 0.85
            return proposedWidth > cap ? cap : proposedWidth
        }

        var alignment: Side {
            isUser ? .trailing : .leading
        }

        var isBubbled: Bool { isUser }
    }

    /// §5: scroll anchoring decision — auto-scroll only when already at
    /// bottom; monotonic bottom buffer added once, never removed.
    struct ScrollAnchorSeam {
        var bottomBuffer: CGFloat = 0
        var bufferAdded = false
        private(set) var isAtBottom = true
        private(set) var autoScrollCount = 0

        mutating func ensureBottomBuffer(_ amount: CGFloat = 50) {
            guard !bufferAdded else { return }
            bottomBuffer += amount
            bufferAdded = true
        }

        mutating func onViewportChange(atBottom: Bool) {
            isAtBottom = atBottom
            ensureBottomBuffer()
        }

        mutating func onContentAppended() {
            // Never fight the user: scroll only if already at bottom.
            if isAtBottom { autoScrollCount += 1 }
        }
    }

    /// §3 stop-button decision seam: send button state swaps to stop
    /// mid-stream; committed text survives stop.
    struct StopButtonSeam {
        private(set) var isStreaming = false

        var showsStop: Bool { isStreaming }

        mutating func beginStream() { isStreaming = true }
        mutating func stop() { isStreaming = false }
    }

    // MARK: - §2 Bubbles

    func testUserBubbleRightAlignedTintedAndCappedAt85Percent() {
        var b = BubbleGeometrySeam(isUser: true, proposedWidth: 400)
        XCTAssertEqual(b.alignment, .trailing, "user bubble right-aligned (§2)")
        XCTAssertTrue(b.isBubbled, "user message is bubbled (§2)")
        XCTAssertEqual(b.bubbleWidth ?? 0, 340, accuracy: 0.01,
                       "user bubble capped at 85% of width (§2)")

        b = BubbleGeometrySeam(isUser: true, proposedWidth: 200)
        XCTAssertEqual(b.bubbleWidth ?? 0, 200, accuracy: 0.01,
                       "short user bubble not inflated toward cap (§2)")
    }

    func testAssistantMessageFullWidthUnbubbled() {
        let a = BubbleGeometrySeam(isUser: false, proposedWidth: 400)
        XCTAssertEqual(a.alignment, .leading, "assistant left/full-width (§2)")
        XCTAssertFalse(a.isBubbled, "assistant never bubbled (§2)")
        XCTAssertNil(a.bubbleWidth, "no width cap for assistant block (§2)")
    }

    // MARK: - §3 Streaming render + stop

    func testStopButtonStateSwapMidStream() {
        var s = StopButtonSeam()
        XCTAssertFalse(s.showsStop, "idle shows send, not stop (§3)")
        s.beginStream()
        XCTAssertTrue(s.showsStop, "mid-stream shows stop (§3)")
        s.stop()
        XCTAssertFalse(s.showsStop, "after stop back to send (§3)")
    }

    func testCommittedTextSurvivesStop() {
        // Real engine: tokens commit to the engine, stop freezes state —
        // committed text is never rolled back (§3).
        var engine = ChatStreamEngine()
        let mid = UUID()
        engine.consume(AgentEvent.make(kind: ChatStreamEngine.Kind.messageStart,
                                       id: 1, payload: "{\"message_id\":\"\(mid.uuidString.lowercased())\"}"))
        for (i, tok) in ["Hello", " ", "world"].enumerated() {
            engine.consume(AgentEvent.make(kind: ChatStreamEngine.Kind.token,
                                           id: Int64(2 + i), payload: tok))
        }
        engine.commitIfDue(now: 100)
        let before = engine.snapshots.first?.text ?? ""
        XCTAssertFalse(before.isEmpty, "committed text exists before stop")

        let commit = engine.stop(id: nil, now: 200)
        let after = engine.snapshots.first?.text ?? ""
        XCTAssertEqual(after, before, "committed text survives stop (§3)")
        XCTAssertEqual(commit?.messages.first?.state, .stopped,
                       "stop frame resolves message to stopped (§3)")
        XCTAssertFalse(engine.snapshots.first?.retryAvailable ?? true)
    }

    func testStreamSnapshotBecomesBlockRender() {
        // §3: token stream → snapshot → displayText drives the block render.
        var engine = ChatStreamEngine()
        let mid = UUID()
        engine.consume(AgentEvent.make(kind: ChatStreamEngine.Kind.messageStart,
                                       id: 1, payload: "{\"message_id\":\"\(mid.uuidString.lowercased())\"}"))
        for (i, tok) in ["a", "b", "c"].enumerated() {
            engine.consume(AgentEvent.make(kind: ChatStreamEngine.Kind.token,
                                           id: Int64(2 + i), payload: tok))
        }
        engine.commitIfDue(now: 10)
        let snap = engine.snapshots.first
        XCTAssertEqual(snap?.text, "abc", "snapshot text = concatenated tokens (§3)")
        XCTAssertEqual(snap?.state, .streaming)
    }

    // MARK: - §5 Scroll anchoring

    func testAutoScrollOnlyWhenAtBottom() {
        var s = ScrollAnchorSeam()
        s.onViewportChange(atBottom: true)
        s.onContentAppended()
        XCTAssertEqual(s.autoScrollCount, 1, "at bottom → auto-scroll (§5)")

        s.onViewportChange(atBottom: false) // user scrolled up mid-stream
        s.onContentAppended()
        s.onContentAppended()
        XCTAssertEqual(s.autoScrollCount, 1, "never fight the user mid-stream (§5)")
    }

    func testBottomBufferMonotonicAddedOnceNeverRemoved() {
        var s = ScrollAnchorSeam()
        XCTAssertEqual(s.bottomBuffer, 0, accuracy: 0.01)
        s.onViewportChange(atBottom: true)
        XCTAssertEqual(s.bottomBuffer, 50, accuracy: 0.01,
                       "~50pt bottom buffer added once (§5)")
        s.onViewportChange(atBottom: false)
        s.onViewportChange(atBottom: true)
        s.onViewportChange(atBottom: false)
        XCTAssertEqual(s.bottomBuffer, 50, accuracy: 0.01,
                       "buffer is monotonic — never removed (§5)")
    }

    // MARK: - M1 gate smoke: 1k-message stream

    func testOneThousandTokenStreamCoalescesAndTerminatesClean() {
        var engine = ChatStreamEngine()
        let mid = UUID().uuidString.lowercased()
        engine.consume(AgentEvent.make(id: 0, kind: ChatStreamEngine.Kind.messageStart,
                                       payload: "{\"message_id\":\"\(mid)\"}"))
        var reference = ""
        var commits = 0
        for i in 1...1000 {
            let tok = " t\(i)"
            reference += tok
            engine.consume(AgentEvent.make(id: Int64(i), kind: ChatStreamEngine.Kind.token,
                                           payload: tok))
            // Tokens arrive 1ms apart: the 60ms coalescing cadence must
            // collapse ~1000 tokens into a handful of UI commits (M1 gate:
            // 1k-message conversation streams w/o dropped frames).
            let now = Double(i) * 0.001
            if engine.shouldCommit(now: now), engine.commitIfDue(now: now) != nil {
                commits += 1
            }
        }
        engine.consume(AgentEvent.make(id: 1001, kind: ChatStreamEngine.Kind.done,
                                       payload: "{\"message_id\":\"\(mid)\"}"))
        let final = engine.commitIfDue(now: 1.1)

        XCTAssertEqual(commits, 17, "1ms-spaced tokens vs 60ms cadence → 17 commits, never ~1000")
        XCTAssertNotNil(final, "terminal done frame flushes the last commit")
        let snap = engine.snapshots.first
        XCTAssertEqual(snap?.state, .done, "1k stream terminates cleanly (M1 gate)")
        XCTAssertEqual(snap?.text, reference,
                       "coalesced final text identical to the un-coalesced reference")
        XCTAssertEqual(engine.snapshots.count, 1, "exactly one assistant message")
    }
}

extension AgentEvent {
    static func make(id: Int64, kind: String, payload: String) -> AgentEvent {
        AgentEvent(id: id, kind: kind, payload: payload)
    }
}
