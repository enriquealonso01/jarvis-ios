import Foundation
import XCTest

import JarvisKit
import Persistence
@testable import FeaturesChat

/// Item 2 TESTER QA — scope item 5 (store round-trip under debounce +
/// cold-launch re-init mid-stream).
///
/// Full chain, no real network:
///   500 tokens → ChatStreamEngine (60ms commit cadence)
///             → StreamPersistenceWriter (500ms debounce)
///             → PersistenceStore.applyStreamDelta
///   …cold launch: a NEW PersistenceStore over the same file +
///   streamRestoreState → engine.seed → live tail resumes.
/// Asserts: snapshot restore, tail continuation, ZERO gap / ZERO duplicate
/// in the final persisted text, terminal finalize flips status, and no
/// message resurrection.
final class Item2StoreRoundTripQATests: XCTestCase {

    private let messageUUID = UUID(uuidString: "6f0a2f58-1e4b-4f6a-9a55-6f0cb2cf6a01")!
    private let conversationUUID = UUID(uuidString: "b1f04de2-88f0-4c8e-9f0a-1f6a2b3c4d5e")!

    private struct FakeClock {
        var now: Double = 1_000.0
        mutating func advance(_ seconds: Double) { now += seconds }
    }

    private func tempDBPath(_ label: String) -> String {
        let dir = NSTemporaryDirectory() + "item2-qa-\(label)-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/store.sqlite"
    }

    private var startID: Int64 { ChatStreamEngine.streamMessageID(forMessageUUID: messageUUID) }

    private func startPayload() -> String { "{\"message_id\": \"\(messageUUID.uuidString.lowercased())\"}" }

    private func makeTokens(_ count: Int) -> [String] {
        let pieces = ["Hel", "lo", " ", "wor", "ld", "!", " ", "—", " ", "ünïcode", " ", "tok", "3n", "\n"]
        return (0..<count).map { pieces[$0 % pieces.count] }
    }

    /// Feed `count` tokens through the engine at 1ms intervals, persisting
    /// every engine commit through the writer's debounce plan. Returns the
    /// writer (its `pending` holds the un-flushed debounced delta).
    private func streamAndPersist(tokens: [String],
                                  engine: inout ChatStreamEngine,
                                  writer: inout StreamPersistenceWriter,
                                  store: PersistenceStore,
                                  clock: inout FakeClock) async throws {
        var seq: Int64 = 0
        for t in tokens {
            seq += 1
            clock.advance(0.001) // tokens 1ms apart; engine cadence = 60ms
            _ = engine.consume(AgentEvent(id: seq, kind: ChatStreamEngine.Kind.token, payload: t))
            if engine.shouldCommit(now: clock.now) {
                if let commit = engine.commitIfDue(now: clock.now) {
                    for snap in commit.messages {
                        let plan = writer.record(snapshot: snap,
                                                 messageID: messageUUID,
                                                 conversationID: conversationUUID,
                                                 now: clock.now)
                        for call in plan.writes {
                            try await store.applyStreamDelta(
                                messageID: call.message.id,
                                conversationID: call.message.conversationID,
                                delta: call.message.content,
                                replaceBody: true,
                                lastEventID: call.lastEventID
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - Core scenario: 500 tokens, debounced, cold re-init mid-stream

    func testColdLaunchMidStreamRestoresSnapshotAndTailsWithoutGapOrDup() async throws {
        let path = tempDBPath("roundtrip")
        var clock = FakeClock()
        let tokens = makeTokens(500)
        let split = 300 // cold launch happens after 300 of the 500 tokens

        // ---- Phase 1: live stream against store instance #1.
        var engine = ChatStreamEngine()
        var writer = StreamPersistenceWriter()
        let firstStore = try PersistenceStore(path: path)
        await firstStore.upsert(StoredConversation(id: conversationUUID, title: "item2 roundtrip"))

        var headTokens = tokens
        headTokens.removeSubrange(split...)
        try await streamAndPersist(tokens: headTokens, engine: &engine, writer: &writer,
                                   store: firstStore, clock: &clock)
        // Pre-launch drain, faithful to real timing: the 60ms commit cadence
        // fires once more for the un-committed tail, and the 500ms debounce
        // timer has long since flushed before a relaunch happens.
        if let tailCommit = engine.commitIfDue(now: clock.now + ChatStreamEngine.minCommitInterval) {
            for snap in tailCommit.messages {
                let plan = writer.record(snapshot: snap, messageID: messageUUID,
                                         conversationID: conversationUUID, now: clock.now)
                for call in plan.writes {
                    try await firstStore.applyStreamDelta(
                        messageID: call.message.id,
                        conversationID: call.message.conversationID,
                        delta: call.message.content,
                        replaceBody: true, lastEventID: call.lastEventID)
                }
            }
        }
        let drain = writer.flush(now: clock.now + StreamPersistenceWriter.debounceInterval)
        for call in drain.writes {
            try await firstStore.applyStreamDelta(
                messageID: call.message.id,
                conversationID: call.message.conversationID,
                delta: call.message.content,
                replaceBody: true, lastEventID: call.lastEventID)
        }
        // The cadence emits the full-prefix delta on every 60ms commit, so
        // the persisted prefix must be a strict prefix of the head tokens
        // and land on a commit boundary. The FINAL text equality (prefix +
        // tail == all 500 tokens) is the no-gap/no-dup verdict in Phase 3.
        let streamingIDs = await firstStore.streamingMessageIDs(conversationID: conversationUUID)
        XCTAssertEqual(streamingIDs, [messageUUID],
                       "mid-stream the message row must exist with status streaming")
        let midState = try await firstStore.streamRestoreState(conversationID: conversationUUID)
        let midSnapshot = midState.snapshot
        XCTAssertNotNil(midSnapshot, "debounced deltas must have persisted a snapshot by now")
        let midText = midSnapshot?.content ?? ""
        XCTAssertEqual(midText, headTokens.joined(),
                       "drained prefix must match the first \(split) tokens exactly")
        XCTAssertGreaterThan(midState.resumeEventID, 0, "resume pointer must be persisted")

        // ---- Phase 2: COLD LAUNCH — brand-new store over the same file.
        let secondStore = try PersistenceStore(path: path)
        let restored = try await secondStore.streamRestoreState(conversationID: conversationUUID)
        let restoredSnapshot = restored.snapshot
        let restoredResume = restored.resumeEventID
        let restoredText = restoredSnapshot?.content ?? ""
        XCTAssertEqual(restoredText, midText, "cold launch must restore the exact persisted prefix")
        XCTAssertEqual(restoredResume, midState.resumeEventID, "resume pointer survives re-init")

        // Fresh engine seeds itself from the restored snapshot (restore path).
        var tailEngine = ChatStreamEngine()
        tailEngine.seed(id: startID, text: restoredText, lastEventID: restoredResume)

        // ---- Phase 3: the live tail continues into the restored message.
        var tailWriter = StreamPersistenceWriter()
        var tailSeq = restoredResume
        var tailClock = clock
        for t in tokens.suffix(from: split) {
            tailSeq += 1
            tailClock.advance(0.001)
            _ = tailEngine.consume(AgentEvent(id: tailSeq, kind: ChatStreamEngine.Kind.token, payload: t))
            if tailEngine.shouldCommit(now: tailClock.now) {
                if let commit = tailEngine.commitIfDue(now: tailClock.now) {
                    for snap in commit.messages {
                        let plan = tailWriter.record(snapshot: snap,
                                                     messageID: messageUUID,
                                                     conversationID: conversationUUID,
                                                     now: tailClock.now)
                        for call in plan.writes {
                            try await secondStore.applyStreamDelta(
                                messageID: call.message.id,
                                conversationID: call.message.conversationID,
                                delta: call.message.content,
                                replaceBody: true,
                                lastEventID: call.lastEventID
                            )
                        }
                    }
                }
            }
        }
        // Terminal done → flush-through finalize (writer drops debounced
        // pending; store row flips to sent).
        tailSeq += 1
        _ = tailEngine.consume(AgentEvent(id: tailSeq, kind: ChatStreamEngine.Kind.done,
                                          payload: startPayload()))
        let finalCommit = tailEngine.commitIfDue(now: tailClock.now + 1)
        XCTAssertNotNil(finalCommit, "terminal frame must flush")
        if let commit = finalCommit {
            for snap in commit.messages {
                let plan = tailWriter.record(snapshot: snap,
                                             messageID: messageUUID,
                                             conversationID: conversationUUID,
                                             now: tailClock.now + 1)
                for call in plan.writes {
                    try await secondStore.finalizeStreamedMessage(
                        id: call.message.id,
                        conversationID: call.message.conversationID,
                        text: call.message.content,
                        failed: call.message.status == .failed,
                        lastEventID: call.lastEventID
                    )
                }
            }
        }

        // ---- Verdicts: exact text, no gap, no dup, terminal status.
        let finalMessages = try await secondStore.messages(conversationID: conversationUUID)
        let assistantRows = finalMessages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantRows.count, 1,
                       "stream must produce exactly ONE message row (no dup rows)")
        let finalText = assistantRows.first?.content ?? ""
        XCTAssertEqual(finalText, tokens.joined(),
                       "restored prefix + tail must reassemble with no gap and no duplicate")
        let finalRow = assistantRows.first
        XCTAssertEqual(finalRow?.status, .sent, "finalize must flip the row to sent")
        XCTAssertEqual(finalRow?.lastEventID, tailSeq, "final resume pointer = last applied seq")
        let afterIDs = await secondStore.streamingMessageIDs(conversationID: conversationUUID)
        XCTAssertTrue(afterIDs.isEmpty, "nothing may look mid-stream after finalize")
        let restoreAfter = try await secondStore.streamRestoreState(conversationID: conversationUUID)
        let afterSnapshot = restoreAfter.snapshot
        XCTAssertNil(afterSnapshot, "no restore candidate after terminal state")
    }

    // MARK: - Restore is idempotent: re-seeding twice never duplicates

    func testRestoreSeedReplayDoesNotDuplicateText() async throws {
        let path = tempDBPath("replay")
        let store = try PersistenceStore(path: path)
        await store.upsert(StoredConversation(id: conversationUUID, title: "restore replay"))
        let persistedPrefix = makeTokens(120).joined()
        try await store.applyStreamDelta(
            messageID: messageUUID, conversationID: conversationUUID,
            delta: persistedPrefix, replaceBody: true, lastEventID: 120
        )

        let state = try await store.streamRestoreState(conversationID: conversationUUID)
        let snapshot = state.snapshot
        let resume = state.resumeEventID
        XCTAssertEqual(snapshot?.content, persistedPrefix)
        XCTAssertEqual(resume, 120)

        // The reconnect replay (ids ≤ watermark) must fold to a no-op…
        var engine = ChatStreamEngine()
        engine.seed(id: startID, text: snapshot?.content ?? "", lastEventID: resume)
        for id in Int64(1)...120 {
            _ = engine.consume(AgentEvent(id: id, kind: ChatStreamEngine.Kind.token, payload: "?"))
        }
        // …and a SECOND restore+seed cycle (double cold launch) is inert too.
        let again = try await store.streamRestoreState(conversationID: conversationUUID)
        let againSnapshot = again.snapshot
        engine.seed(id: startID, text: againSnapshot?.content ?? "", lastEventID: again.resumeEventID)

        let snap = engine.snapshot(id: startID)
        XCTAssertEqual(snap?.text, persistedPrefix,
                       "restore replays must never duplicate restored content")
        XCTAssertEqual(engine.lastSeq, 120)

        // Tail continues from 121 — no gap at the seam.
        _ = engine.consume(AgentEvent(id: 121, kind: ChatStreamEngine.Kind.token, payload: "tail-token"))
        let after = engine.snapshot(id: startID)
        XCTAssertEqual(after?.text, persistedPrefix + "tail-token",
                       "tail must continue exactly at the seam")
    }
}
