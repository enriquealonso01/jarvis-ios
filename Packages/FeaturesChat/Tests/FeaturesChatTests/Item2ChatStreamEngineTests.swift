import Foundation
import XCTest

@testable import FeaturesChat
import Persistence

/// Item 2 BUILDER QA — the engine contract: per-message state machine
/// (pending→streaming→done|failed|stopped), 60ms coalesced commits,
/// monotonic-seq dedupe (resume replay is idempotent), stop freezing
/// partial content, error → retry affordance, and the fixture-contract
/// frame → message mapping (token frames carry raw text and attach to the
/// current message).
final class Item2ChatStreamEngineTests: XCTestCase {
    private func ev(_ id: Int64, _ kind: String, _ payload: String) -> AgentEvent {
        AgentEvent(id: id, kind: kind, payload: payload)
    }

    private func messageStart(_ id: Int64, _ uuid: String) -> AgentEvent {
        ev(id, "message_start", "{\"message_id\": \"\(uuid)\"}")
    }

    private let sampleMessageID = "6f0a2f58-1e4b-4f6a-9a55-6f0cb2cf6a01"

    // MARK: State machine + shared mapping

    func testPendingStreamingDoneMachine() {
        var engine = ChatStreamEngine()
        XCTAssertEqual(engine.consume(messageStart(1, sampleMessageID)), .started)
        let target = ChatStreamEngine.streamMessageID(
            for: messageStart(1, sampleMessageID), current: nil)

        XCTAssertEqual(engine.consume(ev(2, "token", "Hel")), .buffered)
        XCTAssertEqual(engine.consume(ev(3, "token", "lo")), .buffered)
        XCTAssertEqual(engine.snapshot(id: target)?.state, .streaming)
        XCTAssertEqual(engine.snapshot(id: target)?.text, "Hello")

        XCTAssertEqual(engine.consume(ev(4, "done",
            "{\"message_id\": \"\(sampleMessageID)\"}")), .finished)
        XCTAssertEqual(engine.snapshot(id: target)?.state, .done)
        XCTAssertEqual(engine.snapshot(id: target)?.text, "Hello")
        XCTAssertEqual(engine.snapshot(id: target)?.stopReason, .done)
    }

    func testErrorMarksFailedWithRetryAffordance() {
        var engine = ChatStreamEngine()
        _ = engine.consume(messageStart(1, sampleMessageID))
        let target = ChatStreamEngine.streamMessageID(
            for: messageStart(1, sampleMessageID), current: nil)
        _ = engine.consume(ev(2, "token", "Working"))
        _ = engine.consume(ev(3, "error",
            "{\"message_id\": \"\(sampleMessageID)\", \"message\": \"tool timeout\"}"))
        let snap = engine.snapshot(id: target)
        XCTAssertEqual(snap?.state, .failed)
        XCTAssertEqual(snap?.retryAvailable, true, "error frames must offer retry")
        XCTAssertEqual(snap?.text, "Working", "partial text survives failure")
    }

    // MARK: Token frames attach to the current message (fixture contract)

    func testRawTokenFramesAttachToCurrentMessage() {
        var engine = ChatStreamEngine()
        _ = engine.consume(messageStart(1, sampleMessageID))
        _ = engine.consume(ev(2, "token", "a"))
        _ = engine.consume(ev(3, "token", "b"))
        _ = engine.consume(ev(4, "token", "c"))
        // ONE message, not three keyed by frame id.
        XCTAssertEqual(engine.messages.count, 1)
        XCTAssertEqual(engine.snapshots.first?.text, "abc")
    }

    func testMessageStartDoesNotWipeAccumulatedText() {
        var engine = ChatStreamEngine()
        _ = engine.consume(messageStart(1, sampleMessageID))
        _ = engine.consume(ev(2, "token", "kept"))
        // A resume replay of message_start must not reset the buffer.
        _ = engine.consume(messageStart(1, sampleMessageID))
        XCTAssertEqual(engine.snapshots.first?.text, "kept")
    }

    // MARK: Monotonic seq + dedupe

    func testDedupeReplayedFrames() {
        var engine = ChatStreamEngine()
        _ = engine.consume(messageStart(1, sampleMessageID))
        _ = engine.consume(ev(2, "token", "one"))
        // Server replays id ≤ lastSeq after a resume — must be dropped.
        XCTAssertEqual(engine.consume(ev(2, "token", "one")), .buffered)
        XCTAssertEqual(engine.consume(messageStart(1, sampleMessageID)), .buffered)
        _ = engine.consume(ev(3, "token", "two"))
        XCTAssertEqual(engine.snapshots.first?.text, "onetwo")
        XCTAssertEqual(engine.lastSeq, 3)
    }

    func testSeedLiftsDedupeWatermark() {
        var engine = ChatStreamEngine()
        let target = ChatStreamEngine.streamMessageID(forMessageUUID:
            UUID(uuidString: sampleMessageID)!)
        engine.seed(id: target, text: "restored", lastEventID: 41)
        XCTAssertEqual(engine.snapshot(id: target)?.text, "restored")
        // Replay of everything ≤ 41 is dropped; new tail applies.
        XCTAssertEqual(engine.consume(ev(41, "token", "-ghost")), .buffered)
        _ = engine.consume(ev(42, "token", "+live"))
        XCTAssertEqual(engine.snapshot(id: target)?.text, "restored+live")
    }

    // MARK: 60ms coalesced commits (caller-driven clock)

    func testCommitCadenceAndTerminalBypass() {
        var engine = ChatStreamEngine()
        _ = engine.consume(messageStart(1, sampleMessageID))
        let target = ChatStreamEngine.streamMessageID(
            for: messageStart(1, sampleMessageID), current: nil)

        _ = engine.consume(ev(2, "token", "x"))
        // Too soon after init? No — lastCommitAt is -inf, so the FIRST
        // commit fires immediately at t=0…
        let first = engine.commitIfDue(now: 0)
        XCTAssertNotNil(first, "first commit flushes immediately")
        XCTAssertEqual(first?.messages.first?.text, "x")

        // …then the 60ms gate applies.
        _ = engine.consume(ev(3, "token", "y"))
        XCTAssertNil(engine.commitIfDue(now: 0.03), "cadence not elapsed")
        let second = engine.commitIfDue(now: 0.0601)
        XCTAssertEqual(second?.messages.first?.text, "xy")

        // Terminal frames flush immediately, gate or no gate.
        _ = engine.consume(ev(4, "done", "{\"message_id\": \"\(sampleMessageID)\"}"))
        let third = engine.commitIfDue(now: 0.0602)
        XCTAssertNotNil(third, "terminal transitions bypass the cadence")
        XCTAssertEqual(third?.messages.first?.state, .done)
        XCTAssertNil(engine.commitIfDue(now: 0.0603), "nothing dirty after flush")
    }

    // MARK: stop() freezes partial content (UI Law §3)

    func testStopFreezesPartialAndIgnoresLateTokens() {
        var engine = ChatStreamEngine()
        _ = engine.consume(messageStart(1, sampleMessageID))
        let target = ChatStreamEngine.streamMessageID(
            for: messageStart(1, sampleMessageID), current: nil)
        _ = engine.consume(ev(2, "token", "Partial answ"))
        let commit = engine.stop(now: 10)
        XCTAssertEqual(commit?.messages.first?.state, .stopped)
        XCTAssertEqual(commit?.messages.first?.text, "Partial answ")
        XCTAssertEqual(commit?.messages.first?.stopReason, .stopped)
        // Late tokens after the freeze are dropped — no resurrection.
        _ = engine.consume(ev(3, "token", "er"))
        XCTAssertEqual(engine.snapshot(id: target)?.text, "Partial answ")
    }

    func testFailActiveOffersRetryAndFlushesImmediately() {
        var engine = ChatStreamEngine()
        _ = engine.consume(messageStart(1, sampleMessageID))
        _ = engine.consume(ev(2, "token", "so far"))
        let commit = engine.failActive(now: 5)
        XCTAssertEqual(commit?.messages.first?.state, .failed)
        XCTAssertEqual(commit?.messages.first?.retryAvailable, true)
    }
}

/// Item 2 BUILDER QA — persistence integration: debounced stream deltas,
/// final-commit status/preview updates, and cold-launch restore, end-to-end
/// against the real GRDB store (no network).
final class Item2StreamPersistenceTests: XCTestCase {
    private func ev(_ id: Int64, _ kind: String, _ payload: String) -> AgentEvent {
        AgentEvent(id: id, kind: kind, payload: payload)
    }

    private let messageUUIDString = "6f0a2f58-1e4b-4f6a-9a55-6f0cb2cf6a01"

    /// Injectable clock the test can advance (a captured `var` in a closure
    /// would give the closure its own copy).
    private final class ClockBox: @unchecked Sendable {
        var t: Double = 0
    }

    private func makeConversation(_ store: PersistenceStore) async -> UUID {
        let conv = StoredConversation(title: "item2 stream")
        await store.upsert(conv)
        return conv.id
    }

    private func makePipeline(
        conversationID: UUID, store: PersistenceStore, clock: ClockBox
    ) -> ChatStreamPipeline {
        ChatStreamPipeline(conversationID: conversationID,
                           store: store, clock: { [clock] in clock.t })
    }

    // MARK: Final commit → status sent + conversation preview

    func testDoneFrameFinalizesSentWithPreview() async throws {
        let store = PersistenceStore()
        let convID = await makeConversation(store)
        let box = ClockBox()
        let pipeline = makePipeline(conversationID: convID, store: store, clock: box)
        let messageID = try XCTUnwrap(UUID(uuidString: messageUUIDString))

        await pipeline.ingest(ev(1, "message_start", "{\"message_id\": \"\(messageUUIDString)\"}"))
        await pipeline.ingest(ev(2, "token", "Hello, world!"))
        box.t = 1.0
        await pipeline.ingest(ev(3, "done", "{\"message_id\": \"\(messageUUIDString)\"}"))
        // Drain the debounced timer synchronously for the assertion.
        await pipeline.flushDueWrites()

        let row = await store.getMessage(id: messageID)
        XCTAssertEqual(row?.status, .sent, "done must finalize as sent")
        XCTAssertEqual(row?.content, "Hello, world!")
        let conv = await store.get(id: convID)
        XCTAssertEqual(conv?.lastMessagePreview, "Hello, world!",
                       "final commit updates the conversation preview")
    }

    // MARK: Stop freezes the exact partial text in the store

    func testStopFreezesPartialInStore() async throws {
        let store = PersistenceStore()
        let convID = await makeConversation(store)
        let box = ClockBox()
        let pipeline = makePipeline(conversationID: convID, store: store, clock: box)
        let messageID = try XCTUnwrap(UUID(uuidString: messageUUIDString))

        await pipeline.ingest(ev(1, "message_start", "{\"message_id\": \"\(messageUUIDString)\"}"))
        await pipeline.ingest(ev(2, "token", "Partial answ"))
        await pipeline.stop()

        let row = await store.getMessage(id: messageID)
        XCTAssertEqual(row?.status, .sent, "stopped freezes partial content as sent (UI Law §3)")
        XCTAssertEqual(row?.content, "Partial answ",
                       "the store freezes the SAME text the UI froze")
    }

    // MARK: Error → failed row

    func testErrorFrameFinalizesFailed() async throws {
        let store = PersistenceStore()
        let convID = await makeConversation(store)
        let box = ClockBox()
        let pipeline = makePipeline(conversationID: convID, store: store, clock: box)
        let messageID = try XCTUnwrap(UUID(uuidString: messageUUIDString))

        await pipeline.ingest(ev(1, "message_start", "{\"message_id\": \"\(messageUUIDString)\"}"))
        await pipeline.ingest(ev(2, "token", "Working on it…"))
        await pipeline.ingest(ev(3, "error",
            "{\"message_id\": \"\(messageUUIDString)\", \"message\": \"tool timeout\"}"))

        let row = await store.getMessage(id: messageID)
        XCTAssertEqual(row?.status, .failed)
        XCTAssertEqual(row?.content, "Working on it…", "partial text kept for retry")
    }

    // MARK: Cold-launch restore

    func testColdLaunchRestoreContinuesFromResumePoint() async throws {
        let store = PersistenceStore()
        let convID = await makeConversation(store)
        let messageID = try XCTUnwrap(UUID(uuidString: messageUUIDString))

        // Simulate a previous session that died mid-stream: partial text +
        // resume pointer persisted, status still `streaming`.
        _ = try await store.applyStreamDelta(
            messageID: messageID, conversationID: convID,
            delta: "Resume me", replaceBody: false, lastEventID: 41)

        let restored = await store.streamingMessageIDs(conversationID: convID)
        XCTAssertTrue(restored.contains(messageID), "streaming rows are restore candidates")

        // New pipeline seeds from the store, then the live tail continues.
        let box = ClockBox()
        let pipeline = makePipeline(conversationID: convID, store: store, clock: box)
        let streamID = ChatStreamEngine.streamMessageID(forMessageUUID: messageID)
        await pipeline.restore(id: streamID, messageID: messageID,
                               text: "Resume me", lastEventID: 41)
        // Replay of everything ≤ 41 is dropped; the tail appends.
        await pipeline.ingest(ev(41, "token", "-dup"))
        await pipeline.ingest(ev(42, "token", " after reconnect"))
        await pipeline.ingest(ev(43, "done", "{\"message_id\": \"\(messageUUIDString)\"}"))
        await pipeline.flushDueWrites()

        let row = await store.getMessage(id: messageID)
        XCTAssertEqual(row?.content, "Resume me after reconnect",
                       "restore + dedupe + live tail must not duplicate text")
        XCTAssertEqual(row?.status, .sent)
    }

    // MARK: Debounce plan sanity (pure writer logic)

    func testWriterDebounceSchedulesAndTerminalFlushesThrough() {
        var writer = StreamPersistenceWriter()
        // A flush pins the debounce anchor at t=100.
        _ = writer.flush(now: 100)
        let streamSnap = StreamMessageSnapshot(id: 7, state: .streaming,
                                               text: "pending…", lastEventID: 9)
        let plan = writer.record(snapshot: streamSnap,
                                 messageID: UUID(), conversationID: UUID(), now: 100.2)
        XCTAssertEqual(plan.writes.count, 1,
                       "streaming commits emit the full-prefix delta immediately (crash-safe)")
        XCTAssertEqual(plan.scheduleNextFlushAt, 100.5,
                       "500ms timer re-drains as the retry heartbeat")

        let doneSnap = StreamMessageSnapshot(id: 7, state: .done,
                                             text: "final", lastEventID: 12)
        let finalPlan = writer.record(snapshot: doneSnap,
                                      messageID: UUID(), conversationID: UUID(), now: 100.3)
        XCTAssertEqual(finalPlan.writes.count, 1, "terminal commits flush through now")
        XCTAssertEqual(finalPlan.writes.first?.lastEventID, 12, "resume pointer rides along")
        XCTAssertNil(finalPlan.scheduleNextFlushAt)
        XCTAssertEqual(finalPlan.writes.first?.message.status, .sent)
    }
}
