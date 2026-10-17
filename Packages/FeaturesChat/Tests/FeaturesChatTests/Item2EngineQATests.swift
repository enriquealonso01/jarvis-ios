import Foundation
import XCTest

import JarvisKit
@testable import FeaturesChat

/// Item 2 TESTER QA — scope items 2 (replay/dedupe), 3 (coalescing) and
/// 4 (stop semantics) against the real `ChatStreamEngine`.
///
/// Swift 6.2 rule honored: no `await` inside XCTAssert autoclosures —
/// every async result is hoisted into a local first.
final class Item2EngineQATests: XCTestCase {

    // MARK: - Helpers

    /// Deterministic UUID for the streamed message.
    private let messageUUID = UUID(uuidString: "6f0a2f58-1e4b-4f6a-9a55-6f0cb2cf6a01")!

    private struct FakeClock {
        var now: Double = 1_000.0
        mutating func advance(_ seconds: Double) { now += seconds }
    }

    private var startID: Int64 { ChatStreamEngine.streamMessageID(forMessageUUID: messageUUID) }

    private func startPayload(_ uuid: UUID) -> String {
        // Fixture contract: wire message_id is lowercase (see Fixtures/*.sse);
        // uuidString renders uppercase — normalize to the wire form.
        "{\"message_id\": \"\(uuid.uuidString.lowercased())\"}"
    }

    private func commitText(_ commits: [StreamCommit], id: Int64) -> String {
        commits.flatMap { $0.messages.filter { $0.id == id } }.last?.text ?? ""
    }

    // MARK: 2. Replay/dedupe — replayed seq range yields ZERO duplicate tokens

    func testReplayedSeqRangeProducesZeroDuplicateTokens() {
        var clock = FakeClock()
        let live: [(Int64, String, String)] = [
            (1, ChatStreamEngine.Kind.messageStart, startPayload(messageUUID)),
            (2, ChatStreamEngine.Kind.token, "Hel"),
            (3, ChatStreamEngine.Kind.token, "lo"),
            (4, ChatStreamEngine.Kind.token, " wor"),
            (5, ChatStreamEngine.Kind.token, "ld"),
            (6, ChatStreamEngine.Kind.done, startPayload(messageUUID)),
        ]

        // Live pass.
        var liveEngine = ChatStreamEngine()
        for f in live {
            _ = liveEngine.consume(AgentEvent(id: f.0, kind: f.1, payload: f.2))
        }
        _ = liveEngine.commitIfDue(now: clock.now + 1)
        let liveSnap = liveEngine.snapshot(id: startID)
        XCTAssertEqual(liveSnap?.text, "Hello world")
        XCTAssertEqual(liveEngine.lastSeq, 6)

        // Reconnect replay: the server resends the ENTIRE seq range 1…6
        // (worst case — Last-Event-ID ignored). Client-side watermark from
        // the persisted resume pointer must fold every frame to a no-op.
        var replayEngine = ChatStreamEngine()
        replayEngine.seed(id: startID, text: "Hello world", lastEventID: 6)
        var dupEffects: [StreamConsumeEffect] = []
        for f in live {
            dupEffects.append(replayEngine.consume(AgentEvent(id: f.0, kind: f.1, payload: f.2)))
        }
        _ = replayEngine.commitIfDue(now: clock.now + 1)
        let replaySnap = replayEngine.snapshot(id: startID)

        XCTAssertEqual(replaySnap?.text, "Hello world",
                       "replayed seq range must not duplicate any token")
        XCTAssertEqual(replayEngine.lastSeq, 6)
        XCTAssertEqual(replayEngine.bufferedCount, 0,
                       "dedupe must not dirty buffers")
        XCTAssertTrue(dupEffects.allSatisfy { $0 == .buffered },
                      "every replayed frame must be watermarked out")
    }

    func testDuplicateFramesMidStreamAreDeduped() {
        var clock = FakeClock()
        var engine = ChatStreamEngine()
        _ = engine.consume(AgentEvent(id: 1, kind: ChatStreamEngine.Kind.messageStart,
                                      payload: startPayload(messageUUID)))
        _ = engine.consume(AgentEvent(id: 2, kind: ChatStreamEngine.Kind.token, payload: "A"))
        _ = engine.consume(AgentEvent(id: 2, kind: ChatStreamEngine.Kind.token, payload: "A")) // replay
        _ = engine.consume(AgentEvent(id: 3, kind: ChatStreamEngine.Kind.token, payload: "B"))
        _ = engine.consume(AgentEvent(id: 3, kind: ChatStreamEngine.Kind.token, payload: "B")) // replay
        _ = engine.commitIfDue(now: clock.now + 1)
        let snap = engine.snapshot(id: startID)
        XCTAssertEqual(snap?.text, "AB", "duplicate seqs must fold exactly once")
    }

    func testFrameBelowWatermarkIsDroppedAndStreamContinues() {
        var engine = ChatStreamEngine()
        _ = engine.consume(AgentEvent(id: 5, kind: ChatStreamEngine.Kind.token, payload: "five"))
        _ = engine.consume(AgentEvent(id: 2, kind: ChatStreamEngine.Kind.token, payload: "-dropped"))
        _ = engine.consume(AgentEvent(id: 6, kind: ChatStreamEngine.Kind.token, payload: "six"))
        XCTAssertEqual(engine.lastSeq, 6)
        let snap = engine.snapshots.first
        XCTAssertEqual(snap?.text, "fivesix")
    }

    // MARK: 3. Coalescing — 1000 rapid tokens, few commits, identical text

    func testThousandTokensCoalescedWithIdenticalFinalText() {
        let tokens = (0..<1000).map { "t\($0) " }
        let joined = tokens.joined()

        // Reference: commit after EVERY frame (un-coalesced).
        var reference = ChatStreamEngine()
        _ = reference.consume(AgentEvent(id: 1, kind: ChatStreamEngine.Kind.messageStart,
                                         payload: startPayload(messageUUID)))
        var rid: Int64 = 1
        for t in tokens {
            rid += 1
            _ = reference.consume(AgentEvent(id: rid, kind: ChatStreamEngine.Kind.token, payload: t))
            _ = reference.commitIfDue(now: Double(rid)) // 1s steps: always due
        }
        let refSnap = reference.snapshot(id: startID)
        let referenceText = refSnap?.text ?? ""

        // Coalesced: tokens land 1ms apart on the fake clock (60ms cadence).
        var clock = FakeClock()
        var engine = ChatStreamEngine()
        _ = engine.consume(AgentEvent(id: 1, kind: ChatStreamEngine.Kind.messageStart,
                                      payload: startPayload(messageUUID)))
        var seq: Int64 = 1
        var commits = 0
        for t in tokens {
            seq += 1
            clock.advance(0.001)
            _ = engine.consume(AgentEvent(id: seq, kind: ChatStreamEngine.Kind.token, payload: t))
            if engine.shouldCommit(now: clock.now) {
                if engine.commitIfDue(now: clock.now) != nil { commits += 1 }
            }
        }
        // Terminal done → immediate flush.
        seq += 1
        _ = engine.consume(AgentEvent(id: seq, kind: ChatStreamEngine.Kind.done,
                                      payload: startPayload(messageUUID)))
        let finalCommit = engine.commitIfDue(now: clock.now + 1)
        let snap = engine.snapshot(id: startID)
        let coalescedText = snap?.text ?? ""

        XCTAssertEqual(coalescedText, referenceText,
                       "coalesced final text must equal the un-coalesced reference")
        XCTAssertEqual(coalescedText, joined)
        XCTAssertNotNil(finalCommit, "terminal flush must fire")
        XCTAssertLessThan(commits, 100,
                          "1000 rapid tokens must coalesce to far fewer emits")
        XCTAssertGreaterThanOrEqual(commits, 10, "cadence must still emit periodically")
        XCTAssertEqual(engine.bufferedCount, 0, "terminal flush drains the buffer")
        let resume = engine.resumeID
        XCTAssertNil(resume, "terminal message is not live → no resume pointer")
    }

    func testEmitCountScalesWithCommitWindowWhileTextStaysExact() {
        let tokens = (0..<1000).map { "w\($0)" }
        for window in [1, 7, 60, 333, 1000] {
            var clock = FakeClock()
            var engine = ChatStreamEngine()
            engine.seed(id: startID, text: "", lastEventID: 0)
            var seq: Int64 = 0
            var emits = 0
            for t in tokens {
                seq += 1
                _ = engine.consume(AgentEvent(id: seq, kind: ChatStreamEngine.Kind.token, payload: t))
                if seq % Int64(window) == 0 {
                    clock.advance(ChatStreamEngine.minCommitInterval)
                    if engine.commitIfDue(now: clock.now) != nil { emits += 1 }
                }
            }
            clock.advance(ChatStreamEngine.minCommitInterval)
            _ = engine.commitIfDue(now: clock.now) // tail flush
            let snap = engine.snapshot(id: startID)
            XCTAssertEqual(snap?.text, tokens.joined(), "window \(window): text identical")
            if window > 1 {
                XCTAssertLessThan(emits, 1000 / window + 3,
                                  "window \(window): emits coalesced")
            }
        }
    }

    // MARK: 4. Stop semantics — freeze partial, status stopped, no resurrection

    func testStopMidStreamFreezesPartialAsStopped() {
        var clock = FakeClock()
        var engine = ChatStreamEngine()
        _ = engine.consume(AgentEvent(id: 1, kind: ChatStreamEngine.Kind.messageStart,
                                      payload: startPayload(messageUUID)))
        _ = engine.consume(AgentEvent(id: 2, kind: ChatStreamEngine.Kind.token, payload: "Partial answ"))
        _ = engine.commitIfDue(now: clock.now + 1)

        let stopCommit = engine.stop(now: clock.now + 1)
        let postStop = engine.commitIfDue(now: clock.now + 2)
        let snap = engine.snapshot(id: startID)

        XCTAssertEqual(snap?.state, .stopped, "status must be stopped")
        XCTAssertEqual(snap?.stopReason, .stopped)
        XCTAssertEqual(snap?.text, "Partial answ", "partial text frozen, not discarded")
        XCTAssertNotNil(stopCommit, "stop must commit the frozen partial immediately")
        XCTAssertEqual(commitText([stopCommit].compactMap { $0 }, id: startID), "Partial answ")
        XCTAssertNil(postStop, "stop flush is one-shot")
        let retry = snap?.retryAvailable ?? true
        XCTAssertFalse(retry, "user stop offers no retry affordance")
    }

    func testServerStopFrameTerminal() {
        var clock = FakeClock()
        // Fixture-contract wire shape: raw-text tokens, message_id only on
        // message_start / stop payloads.
        let raw = """
        id: 10
        event: message_start
        data: {"message_id": "a2d9c3e1-77b2-4a55-9e01-3f8c5d6b7a02"}

        id: 11
        event: token
        data: Partial answ

        id: 12
        event: stop
        data: {"message_id": "a2d9c3e1-77b2-4a55-9e01-3f8c5d6b7a02"}

        """
        var parser = SSEParser()
        var frames: [AgentEvent] = []
        for line in raw.components(separatedBy: "\n") {
            for ev in parser.feed(line) {
                if let agent = SSEClient.agentEvent(from: ev) { frames.append(agent) }
            }
        }
        for ev in parser.flush() {
            if let agent = SSEClient.agentEvent(from: ev) { frames.append(agent) }
        }
        XCTAssertEqual(frames.count, 3)
        let lastKind = frames.last?.kind
        XCTAssertEqual(lastKind, "stop")

        let stopUUID = UUID(uuidString: "a2d9c3e1-77b2-4a55-9e01-3f8c5d6b7a02")!
        let stopID = ChatStreamEngine.streamMessageID(forMessageUUID: stopUUID)
        var engine = ChatStreamEngine()
        for f in frames { _ = engine.consume(f) }
        _ = engine.commitIfDue(now: clock.now + 1)
        let snap = engine.snapshot(id: stopID)
        XCTAssertEqual(snap?.state, .stopped)
        XCTAssertEqual(snap?.text, "Partial answ")
    }

    func testResumeAfterStopDoesNotResurrectMessage() {
        var clock = FakeClock()
        var engine = ChatStreamEngine()
        _ = engine.consume(AgentEvent(id: 1, kind: ChatStreamEngine.Kind.messageStart,
                                      payload: startPayload(messageUUID)))
        _ = engine.consume(AgentEvent(id: 2, kind: ChatStreamEngine.Kind.token, payload: "partial"))
        _ = engine.commitIfDue(now: clock.now + 1)
        _ = engine.stop(now: clock.now + 1)

        // In-flight frames + reconnect replay AFTER the user stop:
        let late: [AgentEvent] = [
            AgentEvent(id: 3, kind: ChatStreamEngine.Kind.token, payload: " resurrected?"),
            AgentEvent(id: 4, kind: ChatStreamEngine.Kind.token, payload: " more!"),
            AgentEvent(id: 5, kind: ChatStreamEngine.Kind.messageStart,
                       payload: startPayload(messageUUID)),
            AgentEvent(id: 6, kind: ChatStreamEngine.Kind.done,
                       payload: startPayload(messageUUID)),
        ]
        var effects: [StreamConsumeEffect] = []
        for f in late { effects.append(engine.consume(f)) }
        _ = engine.commitIfDue(now: clock.now + 2)

        let after = engine.snapshot(id: startID)
        XCTAssertEqual(after?.text, "partial", "late frames must not resurrect the message")
        XCTAssertEqual(after?.state, .stopped, "state stays stopped")
        XCTAssertEqual(after?.stopReason, .stopped)
        XCTAssertEqual(engine.lastSeq, 6, "watermark advances over delivered frames")
        XCTAssertTrue(effects.contains(.started) || effects.contains(.buffered),
                      "late frames are seen but inert")
    }

    func testStopOnEmptyStreamIsSafeNoOp() {
        var engine = ChatStreamEngine()
        let commit = engine.stop(now: 0)
        XCTAssertNil(commit, "stop with no active message must be a safe no-op")
        XCTAssertTrue(engine.snapshots.isEmpty)
    }

    func testErrorFrameMarksFailedWithRetryAffordance() {
        var clock = FakeClock()
        var engine = ChatStreamEngine()
        _ = engine.consume(AgentEvent(id: 1, kind: ChatStreamEngine.Kind.messageStart,
                                      payload: startPayload(messageUUID)))
        _ = engine.consume(AgentEvent(id: 2, kind: ChatStreamEngine.Kind.token, payload: "Working on it…"))
        _ = engine.consume(AgentEvent(id: 3, kind: ChatStreamEngine.Kind.error,
                                      payload: "{\"message_id\": \"\(messageUUID.uuidString.lowercased())\", \"message\": \"run crashed: tool timeout\"}"))
        _ = engine.commitIfDue(now: clock.now + 1)
        let snap = engine.snapshot(id: startID)
        XCTAssertEqual(snap?.state, .failed)
        XCTAssertEqual(snap?.stopReason, .error)
        let retry = snap?.retryAvailable ?? false
        XCTAssertTrue(retry, "error must surface the retry affordance")
        XCTAssertEqual(snap?.text, "Working on it…", "partial text survives failure")
    }
}
