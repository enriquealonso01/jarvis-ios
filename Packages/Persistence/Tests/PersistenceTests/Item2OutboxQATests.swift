import Foundation
import XCTest

@testable import Persistence

/// Item 2 TESTER QA — scope item 6 (outbox offline enqueue → backonline flush).
/// Asserts STORE STATE end-to-end with an injected transport (no real network):
///   1. While "offline", a POST-shaped payload enqueues and every drain attempt
///      fails WITHOUT acking — the row stays queued, `attempts` grows, backoff
///      pushes `next_retry_at` out.
///   2. "Backonline" (a working transport) + reconnect: backoff resets, the
///      queue drains FIFO, ack removes rows — `outboxCount() == 0` and the
///      delivered payloads are recorded exactly once, in order.
/// Mirrors the real app path: offline send → outbox row; reconnect → flush.
final class Item2OutboxQATests: XCTestCase {

    /// Records successful deliveries (send closure target; actor = Swift 6 safe).
    private actor DeliveryLog {
        var payloads: [OutboxPayload] = []
        func record(_ payload: OutboxPayload) { payloads.append(payload) }
    }

    private enum TransportError: Error { case offline }

    // MARK: - Core scenario: offline enqueue, backonline flush

    func testOfflineEnqueueThenBackonlineFlushViaStoreState() async throws {
        let store = PersistenceStore()
        let log = DeliveryLog()

        let conv = StoredConversation(title: "item2 outbox qa")
        await store.upsert(conv)
        let message = StoredMessage(
            conversationID: conv.id, role: .user, content: "offline send"
        )
        await store.upsert(message)

        // "Offline" transport: every POST fails the way an unreachable
        // network fails — the entry must survive in the queue.
        let offline = OutboxActor(store: store) { _ in throw TransportError.offline }

        let entry = OutboxEntry(
            payload: OutboxPayload(
                kind: "send-message",
                conversationID: conv.id,
                messageID: message.id,
                body: "offline send"
            ),
            nextRetryAt: Date(timeIntervalSince1970: 0) // due immediately
        )
        await store.enqueue(entry)

        // STORE STATE after the offline POST: enqueued exactly once.
        var queued = await store.outboxCount()
        XCTAssertEqual(queued, 1, "offline POST must enqueue exactly one row")
        var persisted = await store.outboxEntry(id: entry.id)
        XCTAssertEqual(persisted?.payload.kind, "send-message")
        XCTAssertEqual(persisted?.payload.body, "offline send")
        XCTAssertEqual(persisted?.attempts, 0, "enqueue alone must not burn attempts")

        // Drain while offline: nothing sends, nothing acks.
        let sentOffline = try await offline.drainOnce(now: 1_000)
        XCTAssertEqual(sentOffline, 0, "offline drain must not ack anything")
        queued = await store.outboxCount()
        XCTAssertEqual(queued, 1, "failed send must KEEP the entry queued")
        persisted = await store.outboxEntry(id: entry.id)
        XCTAssertEqual(persisted?.attempts, 1, "failed attempt must increment attempts")
        let retryAt = persisted?.nextRetryAt.timeIntervalSince1970 ?? -1
        XCTAssertGreaterThan(retryAt, 1_000,
                             "backoff must push next_retry_at into the future")

        // "Backonline": working transport + reconnect path — backoff resets
        // and the queue flushes immediately.
        let online = OutboxActor(store: store) { entry in
            await log.record(entry.payload)
        }
        let flushed = try await online.drainOnReconnect(now: 2_000)
        XCTAssertEqual(flushed, 1, "reconnect must flush the pending entry")

        // STORE STATE after backonline: queue empty, payload delivered once.
        queued = await store.outboxCount()
        XCTAssertEqual(queued, 0, "backonline flush must empty the outbox")
        let gone = await store.outboxEntry(id: entry.id)
        XCTAssertNil(gone, "acked entry must be removed from the store")
        let delivered = await log.payloads
        XCTAssertEqual(delivered.count, 1, "payload must be delivered exactly once")
        XCTAssertEqual(delivered.first?.body, "offline send")
        XCTAssertEqual(delivered.first?.messageID, message.id)
    }

    // MARK: - FIFO + multi-entry flush ordering

    func testBackonlineFlushDrainsAllEntriesInFIFOOrder() async throws {
        let store = PersistenceStore()
        let log = DeliveryLog()

        // Three entries enqueued offline with staggered enqueue times; the
        // middle one already carrying backoff from earlier failures.
        let bodies = ["first", "second", "third"]
        for (index, body) in bodies.enumerated() {
            await store.enqueue(OutboxEntry(
                payload: OutboxPayload(kind: "send-message", body: body),
                attempts: index, // middle/third pretend earlier failures
                nextRetryAt: Date(timeIntervalSince1970: Double(100 * index))
            ))
        }
        var queued = await store.outboxCount()
        XCTAssertEqual(queued, 3, "all offline POSTs must be enqueued")

        let offline = OutboxActor(store: store) { _ in throw TransportError.offline }
        let sentWhileOffline = try await offline.drainOnce(now: 1_000)
        XCTAssertEqual(sentWhileOffline, 0)
        queued = await store.outboxCount()
        XCTAssertEqual(queued, 3, "offline drain must ack nothing")

        let online = OutboxActor(store: store) { entry in
            await log.record(entry.payload)
        }
        let flushed = try await online.drainOnReconnect(now: 2_000)
        XCTAssertEqual(flushed, 3, "reconnect must flush every pending entry")
        queued = await store.outboxCount()
        XCTAssertEqual(queued, 0, "outbox must be empty after the flush")
        let delivered = await log.payloads
        XCTAssertEqual(delivered.map(\.body), bodies,
                       "flush must drain FIFO by enqueue time, exactly once each")
    }

    // MARK: - Late-arriving entries keep the ladder honest after reconnect

    func testReconnectFlushDoesNotResurrectAckedEntries() async throws {
        let store = PersistenceStore()
        let log = DeliveryLog()

        let entry = OutboxEntry(
            payload: OutboxPayload(kind: "send-message", body: "one-shot"),
            nextRetryAt: Date(timeIntervalSince1970: 0)
        )
        await store.enqueue(entry)

        // Offline failure first (row stays, attempts=1)…
        let offline = OutboxActor(store: store) { _ in throw TransportError.offline }
        _ = try await offline.drainOnce(now: 1_000)

        // …then TWO reconnect flushes with a working transport. The second
        // flush must be a no-op: acked rows never come back.
        let online = OutboxActor(store: store) { entry in
            await log.record(entry.payload)
        }
        let firstFlush = try await online.drainOnReconnect(now: 2_000)
        XCTAssertEqual(firstFlush, 1)
        let secondFlush = try await online.drainOnReconnect(now: 3_000)
        XCTAssertEqual(secondFlush, 0, "a second reconnect must find nothing to send")
        let delivered = await log.payloads
        XCTAssertEqual(delivered.count, 1, "no duplicate delivery across reconnects")
        let finalQueued = await store.outboxCount()
        XCTAssertEqual(finalQueued, 0)
    }
}
