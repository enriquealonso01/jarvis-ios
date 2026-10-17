import Foundation
import XCTest

@testable import JarvisKit

/// Item 2 TESTER QA — scope item 1 (SSE parsing correctness).
///
/// Drives the REAL wire path: fixture files (JarvisKit/Fixtures/*.sse, the
/// contract-first shapes from plan Risk-3) go line-by-line through
/// `SSEParser` exactly as `SSEClient`'s read loop feeds it, then through
/// `agentEvent(from:)` exactly as the ingest actor maps them.
/// Covered: multi-line data, CRLF variants, `event:` types, id advancing
/// (native + legacy envelope), malformed frames skipped without killing the
/// parse session, comment/keepalive tolerance.
final class Item2SSEParserQATests: XCTestCase {

    // MARK: - Helpers

    private func lines(_ raw: String) -> [String] {
        raw.components(separatedBy: "\n")
    }

    /// Feed a raw byte string (LF or CRLF) through the parser like the
    /// transport's line iterator would: split on \n, hand each line to
    /// `feed` (the parser itself strips a trailing \r), then flush at EOF.
    private func parse(raw: String) -> [SSEEvent] {
        var parser = SSEParser()
        var events: [SSEEvent] = []
        for line in lines(raw) {
            events.append(contentsOf: parser.feed(line))
        }
        events.append(contentsOf: parser.flush())
        return events
    }

    /// Locate the JarvisKit resource bundle across link contexts (dynamic:
    /// inside the module bundle's resources; static: sibling of the test
    /// bundle), falling back to the test bundle itself.
    private func fixturesBundle() -> Bundle? {
        let candidates = [
            Bundle(for: SSEClient.self),          // JarvisKit class → module bundle
            Bundle(for: Item2SSEParserQATests.self), // the test bundle
            Bundle.main,
        ]
        for bundle in candidates {
            if bundle.url(forResource: "stream-sample", withExtension: "sse") != nil {
                return bundle
            }
            if let url = bundle.url(forResource: "JarvisKit_JarvisKit", withExtension: "bundle"),
               let inner = Bundle(url: url) {
                return inner
            }
        }
        return nil
    }

    /// Fixture content; identical embedded literals as fallback so a bundle
    /// discovery miss degrades to literal-driven coverage, never a failure.
    private func fixture(_ name: String) throws -> String {
        let embedded: [String: String] = [
            "stream-sample": """
            id: 1
            event: message_start
            data: {"message_id": "6f0a2f58-1e4b-4f6a-9a55-6f0cb2cf6a01"}

            id: 2
            event: token
            data: Hello

            id: 3
            event: token
            data: ,

            id: 4
            event: token
            data:  world
            data: !

            id: 5
            event: done
            data: {"message_id": "6f0a2f58-1e4b-4f6a-9a55-6f0cb2cf6a01"}

            """,
        ]
        if let bundle = fixturesBundle(),
           let url = bundle.url(forResource: name, withExtension: "sse"),
           let raw = try? String(contentsOf: url, encoding: .utf8) {
            return raw
        }
        guard let raw = embedded[name] else {
            throw XCTSkip("fixture \(name).sse unavailable in this context")
        }
        return raw
    }

    private func agentEvents(_ sseEvents: [SSEEvent]) -> [AgentEvent] {
        sseEvents.compactMap(SSEClient.agentEvent(from:))
    }

    // MARK: 1. Native fixture: multi-line data, event: types, ids advance

    func testNativeFixtureReplayThroughParser() throws {
        let raw = try fixture("stream-sample")
        let sse = parse(raw: raw)
        let events = agentEvents(sse)

        // 5 dispatched events: message_start, token, token, token(2 data
        // lines), done — everything on the wire maps to exactly one event.
        XCTAssertEqual(sse.count, 5, "fixture must dispatch exactly 5 SSE events")
        XCTAssertEqual(events.count, 5, "every dispatched event must map to an AgentEvent")

        // event: types carry the kind; ids advance monotonically.
        XCTAssertEqual(events.map(\.kind), ["message_start", "token", "token", "token", "done"])
        XCTAssertEqual(events.map(\.id), [1, 2, 3, 4, 5], "ids must advance 1→5")

        // Multi-line data (event 4: two `data:` lines) joins with \n —
        // spec rule; both fragments survive in order.
        XCTAssertEqual(events[3].payload, " world\n!")
        let text = events.filter { $0.kind == "token" }.map(\.payload).joined()
        XCTAssertEqual(text, "Hello, world\n!", "token payloads must concatenate losslessly")

        // message_start/done payloads are the contract's JSON envelope.
        XCTAssertTrue(events[0].payload.contains("6f0a2f58-1e4b-4f6a-9a55-6f0cb2cf6a01"))
        XCTAssertTrue(events[4].payload.contains("6f0a2f58-1e4b-4f6a-9a55-6f0cb2cf6a01"))
    }

    // MARK: 2. CRLF variants parse identically to LF

    func testCRLFLineEndingsParseIdentically() throws {
        let raw = try fixture("stream-sample")
        let lf = parse(raw: raw)

        let crlfRaw = raw.replacingOccurrences(of: "\n", with: "\r\n")
        let crlf = parse(raw: crlfRaw)

        XCTAssertEqual(crlf, lf, "CRLF wire form must produce identical events")
        XCTAssertEqual(crlf.count, 5)
        XCTAssertEqual(crlf.last?.event, "done")
    }

    // MARK: 3. Legacy JSON envelope + comments + id fallback rules

    func testLegacyEnvelopeAndHeartbeatComment() throws {
        let raw = try fixture("stream-legacy-envelope")
        let events = agentEvents(parse(raw: raw))

        XCTAssertEqual(events.count, 4, "': hb' comment must NOT dispatch an event")
        XCTAssertEqual(events.map(\.kind), ["message_start", "token", "token", "done"])

        // No `event:` field → kind comes from the data JSON; id: field wins
        // over the JSON id (both agree here: 30…34 minus the comment).
        XCTAssertEqual(events.map(\.id), [30, 31, 33, 34])

        let text = events.filter { $0.kind == "token" }.map(\.payload).joined()
        XCTAssertEqual(text, "Legacy envelope stream — still alive after heartbeat")
    }

    func testIDFallsBackToPayloadWhenIDFieldAbsent() throws {
        let events = agentEvents(parse(raw: """
        data: {"id": 77, "kind": "token", "payload": "x"}

        """))
        XCTAssertEqual(events.first?.id, 77, "missing id: field must fall back to the JSON id")
        XCTAssertEqual(events.first?.kind, "token")
    }

    func testNULInIDFieldIsIgnoredPerSpec() throws {
        // Spec: an id field containing NUL must be ignored — the event's id
        // then comes from the payload fallback (13 here), not the NUL'd id.
        let events = agentEvents(parse(raw: """
        id: bad\u{0}
        data: {"id": 13, "kind": "token", "payload": "nul"}

        """))
        XCTAssertEqual(events.first?.id, 13)
    }

    // MARK: 4. Malformed frames are SKIPPED — the session keeps parsing

    func testMalformedFramesSkippedWithoutKillingParse() throws {
        let events = agentEvents(parse(raw: """
        id: 1
        event: token
        data: good-1

        data: {not json at all

        data:

        event: orphan-with-no-data

        : keepalive while broken

        total garbage line

        id: 2
        event: token
        data: good-2

        id: 3
        event: done
        data: {"message_id": "m"}

        """))
        // The malformed/garbage frames vanish; the surrounding valid frames
        // survive IN ORDER — the connection-equivalent was never killed.
        XCTAssertEqual(events.map(\.kind), ["token", "token", "done"])
        XCTAssertEqual(events.map(\.id), [1, 2, 3])
        XCTAssertEqual(events[0].payload, "good-1")
        XCTAssertEqual(events[1].payload, "good-2")
    }

    func testUnterminatedFinalEventFlushesAtEOF() throws {
        // Server died mid-frame: the buffered event still ships at flush
        // (finishConnection path) instead of being silently lost.
        var parser = SSEParser()
        let fed = parser.feed("id: 9")
            + parser.feed("event: token")
            + parser.feed("data: tail")
        XCTAssertEqual(fed.count, 0, "nothing dispatches without the blank line")
        let flushed = parser.flush()
        XCTAssertEqual(flushed.count, 1)
        XCTAssertEqual(agentEvents(flushed).first?.payload, "tail")
        XCTAssertEqual(agentEvents(flushed).first?.id, 9)
    }

    // MARK: 5. Resume fixture: retry field parsed, ids reachable

    func testResumeFixtureParsesAndCapturesRetry() throws {
        let raw = try fixture("stream-resume-replay")
        var parser = SSEParser()
        var events: [SSEEvent] = []
        for line in lines(raw) { events.append(contentsOf: parser.feed(line)) }
        events.append(contentsOf: parser.flush())

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.id), ["40", "41"], "wire ids are strings")
        XCTAssertEqual(parser.retryMilliseconds, 1500, "server retry: must be captured")
        let events40 = agentEvents(events)
        XCTAssertEqual(events40.first?.kind, "message_start")
        XCTAssertEqual(events40.last?.payload, "Resume me after reconnect.")
    }

    // MARK: 6. Pure reconnect helpers: terminal vs retryable, backoff curve

    func testTerminalErrorClassification() {
        XCTAssertTrue(SSEClient.isTerminal(SSEError.badStatus(404)))
        XCTAssertTrue(SSEClient.isTerminal(SSEError.badStatus(401)))
        XCTAssertTrue(SSEClient.isTerminal(SSEError.badURL("x")))
        XCTAssertTrue(SSEClient.isTerminal(SSEError.badResponse))
        XCTAssertFalse(SSEClient.isTerminal(SSEError.badStatus(429)), "429 must be retried")
        XCTAssertFalse(SSEClient.isTerminal(SSEError.badStatus(503)), "5xx must be retried")
    }

    func testBackoffDelayCurve() {
        // base * 2^n, capped at 60, ±25% jitter: jitter 0.5 = no offset.
        XCTAssertEqual(SSEClient.backoffDelay(attempt: 0, jitter: 0.5), 1, accuracy: 0.0001)
        XCTAssertEqual(SSEClient.backoffDelay(attempt: 3, jitter: 0.5), 8, accuracy: 0.0001)
        XCTAssertEqual(SSEClient.backoffDelay(attempt: 10, jitter: 0.5), 60, accuracy: 0.0001,
                       "backoff must cap at 60s")
        // Jitter extremes stay inside ±25% of the capped delay.
        let low = SSEClient.backoffDelay(attempt: 4, jitter: 0.0)
        let high = SSEClient.backoffDelay(attempt: 4, jitter: 1.0)
        XCTAssertEqual(low, 16 * 0.75, accuracy: 0.0001)
        XCTAssertEqual(high, 16 * 1.25, accuracy: 0.0001)
    }

    // MARK: 7. Legacy single-line helper (pinned Item 0 surface) still holds

    func testLegacyParseEventLineContractUnchanged() {
        let good = SSEClient.parseEvent(
            "data: {\"id\": 7, \"kind\": \"token\", \"payload\": \"hi\"}"
        )
        XCTAssertEqual(good?.id, 7)
        XCTAssertEqual(good?.kind, "token")
        XCTAssertEqual(good?.payload, "hi")
        XCTAssertNil(SSEClient.parseEvent("data: {broken"))
        XCTAssertNil(SSEClient.parseEvent("event: token"))
    }

    // MARK: 8. Stream endpoint per fixture contract

    func testStreamEndpointShape() {
        let id = UUID(uuidString: "b1f04de2-88f0-4c8e-9f0a-1f6a2b3c4d5e")!
        XCTAssertEqual(SSEClient.streamEndpoint(id),
                       "/v1/conversations/b1f04de2-88f0-4c8e-9f0a-1f6a2b3c4d5e/events")
    }
}
