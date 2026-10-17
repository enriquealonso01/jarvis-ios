import Foundation
import XCTest

@testable import JarvisKit

/// Item 2 QA — the committed SSE fixtures (JarvisKit/Fixtures/, plan Risk-3)
/// replay through the exact parser the live connection uses. The fixtures
/// are the contract: if these tests pass, the transport speaks the shape
/// both the Hermes gateway and future UI previews rely on.
final class Item2SSEFixtureTests: XCTestCase {
    private func loadFixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "sse", subdirectory: "Fixtures"),
            "fixture \(name).sse missing from the JarvisKit resource bundle"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func parse(_ text: String) -> [SSEEvent] {
        var parser = SSEParser()
        var events: [SSEEvent] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            events.append(contentsOf: parser.feed(String(line)))
        }
        events.append(contentsOf: parser.flush())
        return events
    }

    private func agentEvents(_ text: String) -> [AgentEvent] {
        parse(text).compactMap(SSEClient.agentEvent(from:))
    }

    // MARK: Native stream — multi-line data, id/event/data per event

    func testSampleFixtureEndToEnd() throws {
        let events = agentEvents(try loadFixture("stream-sample"))
        XCTAssertEqual(events.count, 5, "message_start + 3 tokens + done")

        XCTAssertEqual(events[0].id, 1)
        XCTAssertEqual(events[0].kind, "message_start")
        XCTAssertTrue(events[0].payload.contains("6f0a2f58"))

        XCTAssertEqual(events[1].kind, "token")
        XCTAssertEqual(events[1].payload, "Hello")
        XCTAssertEqual(events[2].payload, ",")

        // id:4 carries TWO data lines — spec rule: joined with \n.
        XCTAssertEqual(events[3].id, 4)
        XCTAssertEqual(events[3].payload, " world\n!")

        XCTAssertEqual(events[4].kind, "done")
    }

    // MARK: Stop / error terminals

    func testStopMidwayFixture() throws {
        let events = agentEvents(try loadFixture("stream-stop-midway"))
        XCTAssertEqual(events.map(\.kind), ["message_start", "token", "stop"])
        XCTAssertEqual(events[1].payload, "Partial answ")
    }

    func testErrorFixtureCarriesReason() throws {
        let events = agentEvents(try loadFixture("stream-error"))
        XCTAssertEqual(events.last?.kind, "error")
        XCTAssertTrue(events.last?.payload.contains("tool timeout") ?? false)
    }

    // MARK: Legacy JSON envelope shares the stream

    func testLegacyEnvelopeFixture() throws {
        let events = agentEvents(try loadFixture("stream-legacy-envelope"))
        XCTAssertEqual(events.count, 4, "heartbeat comment line yields no event")
        XCTAssertEqual(events.map(\.kind), ["message_start", "token", "token", "done"])
        XCTAssertEqual(events[1].payload, "Legacy envelope stream")
        XCTAssertEqual(events[2].payload, " — still alive after heartbeat")
        XCTAssertEqual(events[3].id, 34)
    }

    // MARK: Resume replay + retry field

    func testResumeReplayFixtureParsesRetryField() throws {
        let text = try loadFixture("stream-resume-replay")
        var parser = SSEParser()
        var seenRetry: Int?
        var events: [SSEEvent] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            events.append(contentsOf: parser.feed(String(line)))
            if let ms = parser.retryMilliseconds { seenRetry = ms }
        }
        XCTAssertEqual(seenRetry, 1500, "`retry:` is a FIELD, not an event kind")
        XCTAssertEqual(events.count, 2, "start + token — the retry field is not an event")
        let agent = agentEvents(text)
        XCTAssertEqual(agent.count, 2, "the retry field never becomes an AgentEvent")
        XCTAssertEqual(agent.last?.payload, "Resume me after reconnect.")
    }

    // MARK: Pure helpers

    func testBackoffDelayExponentialCappedJittered() {
        // jitter 0.5 → no offset (maps to exactly the capped base).
        XCTAssertEqual(SSEClient.backoffDelay(attempt: 0, jitter: 0.5, base: 1), 1)
        XCTAssertEqual(SSEClient.backoffDelay(attempt: 3, jitter: 0.5, base: 1), 8)
        XCTAssertEqual(SSEClient.backoffDelay(attempt: 10, jitter: 0.5, base: 1, maxDelay: 60), 60)
        // Jitter bounds: ±25% of the capped delay.
        let lo = SSEClient.backoffDelay(attempt: 2, jitter: 0.0, base: 1)
        let hi = SSEClient.backoffDelay(attempt: 2, jitter: 1.0, base: 1)
        XCTAssertEqual(lo, 3, accuracy: 0.0001)
        XCTAssertEqual(hi, 5, accuracy: 0.0001)
    }

    func testTerminalErrorClassification() {
        XCTAssertTrue(SSEClient.isTerminal(SSEError.badStatus(401)))
        XCTAssertTrue(SSEClient.isTerminal(SSEError.badStatus(404)))
        XCTAssertFalse(SSEClient.isTerminal(SSEError.badStatus(429))) // retryable
        XCTAssertFalse(SSEClient.isTerminal(SSEError.badStatus(503)))
        XCTAssertTrue(SSEClient.isTerminal(SSEError.badURL("/x")))
    }

    func testStreamEndpointShape() {
        let id = UUID(uuidString: "b1f04de2-88f0-4c8e-9f0a-1f6a2b3c4d5e")!
        XCTAssertEqual(SSEClient.streamEndpoint(id),
                       "/v1/conversations/\(id.uuidString)/events")
    }
}
