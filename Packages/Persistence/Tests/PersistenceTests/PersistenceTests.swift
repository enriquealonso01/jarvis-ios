import Foundation
import XCTest

@testable import Persistence

final class PersistenceTests: XCTestCase {
    func makeStore() -> PersistenceStore { PersistenceStore() }

    // MARK: - Migration contract (pinned)

    func testMigrationChainValidator() {
        XCTAssertTrue(Schema.isWellOrdered([
            Migration(identifier: "a", order: 1),
            Migration(identifier: "b", order: 2),
        ]))
        XCTAssertFalse(Schema.isWellOrdered([
            Migration(identifier: "b", order: 2),
            Migration(identifier: "a", order: 1),
        ]))
        // Duplicate identifiers are not well-ordered.
        XCTAssertFalse(Schema.isWellOrdered([
            Migration(identifier: "a", order: 1),
            Migration(identifier: "a", order: 2),
        ]))
        // The shipped chain must satisfy its own contract.
        XCTAssertTrue(Schema.isWellOrdered(Schema.migrations))
        // v1 is exactly one migration, first in the chain (Item 0 pin).
        XCTAssertEqual(Schema.migrations.first, Schema.Migrations.v1)
        XCTAssertEqual(Schema.Migrations.v1.identifier, "v1.core-tables")
        XCTAssertEqual(Schema.Migrations.v1.order, 1)
    }

    // MARK: - Conversations (Item 0 smoke contract on real GRDB)

    func testStoreUpsertGet() async {
        let store = makeStore()
        let count0 = await store.count()
        XCTAssertEqual(count0, 0, "fresh store must start empty")

        let conv = StoredConversation(title: "Krendora orders")
        await store.upsert(conv)
        let fetched = await store.get(id: conv.id)
        XCTAssertEqual(fetched, conv)
        let count1 = await store.count()
        XCTAssertEqual(count1, 1)

        // Upsert semantics (not append): same id replaces, count stays 1.
        var updated = conv
        updated.title = "Krendora orders v2"
        await store.upsert(updated)
        let count2 = await store.count()
        XCTAssertEqual(count2, 1, "upsert must not duplicate rows")
        let refetched = await store.get(id: conv.id)
        XCTAssertEqual(refetched?.title, "Krendora orders v2")
    }

    // MARK: - Schema v1 tables + FTS triggers

    func testV1MigrationRunsAndTablesExist() async {
        let store = makeStore()
        let conv = StoredConversation(title: "schema")
        await store.upsert(conv)
        let count = await store.count()
        XCTAssertEqual(count, 1)
        // Message insert exercises FK + FTS triggers end to end.
        let message = StoredMessage(conversationID: conv.id, role: .user, content: "hello world")
        await store.upsert(message)
        let messages = await store.messageCount(conversationID: conv.id)
        XCTAssertEqual(messages, 1)
        // The conversation touch wrote the preview.
        let touched = await store.get(id: conv.id)
        XCTAssertEqual(touched?.lastMessagePreview, "hello world")
    }

    // MARK: - Message pagination (50/page, pinned)

    func testMessagePagination() async throws {
        let store = makeStore()
        let conv = StoredConversation(title: "pagination")
        await store.upsert(conv)
        let base = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<120 {
            await store.upsert(StoredMessage(
                conversationID: conv.id,
                role: i.isMultiple(of: 2) ? .user : .assistant,
                content: "msg \(i)",
                createdAt: base.addingTimeInterval(Double(i))
            ))
        }
        let total = await store.messageCount(conversationID: conv.id)
        XCTAssertEqual(total, 120)

        let page0 = try await store.fetchMessages(conversationID: conv.id, page: 0)
        let page1 = try await store.fetchMessages(conversationID: conv.id, page: 1)
        let page2 = try await store.fetchMessages(conversationID: conv.id, page: 2)
        XCTAssertEqual(page0.count, 50, "page size must be 50")
        XCTAssertEqual(page1.count, 50)
        XCTAssertEqual(page2.count, 20)
        XCTAssertEqual(page0.first?.content, "msg 0", "oldest message first")
        XCTAssertEqual(page1.first?.content, "msg 50", "pages advance without overlap")
        XCTAssertEqual(page2.last?.content, "msg 119", "newest message last")
        // Default page size constant is the pinned contract.
        XCTAssertEqual(PersistenceStore.messagePageSize, 50)

        // Chat-style newest page renders oldest-first within the page.
        let recent = try await store.recentMessages(conversationID: conv.id)
        XCTAssertEqual(recent.count, 50)
        XCTAssertEqual(recent.first?.content, "msg 70")
        XCTAssertEqual(recent.last?.content, "msg 119")
    }

    // MARK: - Message status lifecycle

    func testMessageStatusLifecycle() async throws {
        let store = makeStore()
        let conv = StoredConversation(title: "status")
        await store.upsert(conv)
        let raw = ["sending", "sent", "failed", "streaming"]
        XCTAssertEqual(raw, MessageStatus.allCases.map(\.rawValue))

        var m = StoredMessage(conversationID: conv.id, role: .user, content: "ping")
        XCTAssertEqual(m.status, .sending)
        await store.upsert(m)
        m.status = .sent
        await store.upsert(m)
        let fetched = await store.getMessage(id: m.id)
        XCTAssertEqual(fetched?.status, .sent)
    }

    // MARK: - Attachments JSON round-trip

    func testAttachmentsJSONRoundTrip() async {
        let store = makeStore()
        let conv = StoredConversation(title: "attach")
        await store.upsert(conv)
        let atts = [
            StoredAttachment(kind: "image", name: "photo.png"),
            StoredAttachment(kind: "file", name: "invoice.pdf", localPath: "/tmp/invoice.pdf"),
        ]
        let m = StoredMessage(conversationID: conv.id, role: .user,
                              content: "with attachments", attachments: atts)
        await store.upsert(m)
        let fetched = await store.getMessage(id: m.id)
        XCTAssertEqual(fetched?.attachments, atts)
    }

    // MARK: - Streaming delta upsert (cold-launch restore path)

    func testStreamDeltaAppendUpsertsInPlace() async throws {
        let store = makeStore()
        let conv = StoredConversation(title: "stream")
        await store.upsert(conv)
        let mid = UUID()

        // Token deltas append into ONE row.
        _ = try await store.applyStreamDelta(messageID: mid, conversationID: conv.id, delta: "Hel", replaceBody: false)
        _ = try await store.applyStreamDelta(messageID: mid, conversationID: conv.id, delta: "lo ", replaceBody: false)
        _ = try await store.applyStreamDelta(messageID: mid, conversationID: conv.id, delta: "world", replaceBody: false)

        let msgs = try await store.messages(conversationID: conv.id)
        XCTAssertEqual(msgs.count, 1, "deltas must upsert, not append rows")
        XCTAssertEqual(msgs[0].content, "Hello world")
        XCTAssertEqual(msgs[0].status, .streaming)

        // Replace mode (snapshot commit) overwrites.
        _ = try await store.applyStreamDelta(messageID: mid, conversationID: conv.id, delta: "Hello, world!", replaceBody: true)
        let after = await store.getMessage(id: mid)
        XCTAssertEqual(after?.content, "Hello, world!")
        let count = try await store.messages(conversationID: conv.id).count
        XCTAssertEqual(count, 1)
    }

    func testColdLaunchMidStreamRestoresTranscript() async throws {
        let store = makeStore()
        let conv = StoredConversation(title: "cold")
        await store.upsert(conv)
        let mid = UUID()
        _ = try await store.applyStreamDelta(messageID: mid, conversationID: conv.id, delta: "partial to", replaceBody: false)
        _ = try await store.applyStreamDelta(messageID: mid, conversationID: conv.id, delta: "kens", replaceBody: false)

        // Fresh read path restores the partial body (mid-stream state survives).
        let restored = try await store.messages(conversationID: conv.id)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].id, mid)
        XCTAssertEqual(restored[0].content, "partial tokens")
        let convRestored = await store.get(id: conv.id)
        XCTAssertNotNil(convRestored)
    }

    // MARK: - FTS5 search

    func testFTSMessageSearch() async throws {
        let store = makeStore()
        let conv = StoredConversation(title: "fts")
        await store.upsert(conv)
        await store.upsert(StoredMessage(conversationID: conv.id, role: .user, content: "Krendora order status please"))
        await store.upsert(StoredMessage(conversationID: conv.id, role: .assistant, content: "The order shipped today"))
        let target = StoredMessage(conversationID: conv.id, role: .user, content: "What about the budget?")
        await store.upsert(target)

        let hits = try await store.searchMessages(matching: "budget")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].id, target.id)

        // Update keeps the index in sync (synchronize-with-table triggers).
        var edited = target
        edited.content = "Nothing about budgets here"
        await store.upsert(edited)
        let afterEdit = try await store.searchMessages(matching: "budget")
        XCTAssertTrue(afterEdit.contains { $0.id == target.id },
                      "edited content still mentions 'budgets' — index must reflect it")

        // Delete removes it from the index (cascade keeps FTS clean).
        _ = await store.deleteConversation(id: conv.id)
        let afterDelete = try await store.searchMessages(matching: "budget")
        XCTAssertEqual(afterDelete.count, 0)

        // Empty / whitespace query never hits FTS (MATCH would throw).
        let empty = try await store.searchMessages(matching: "   ")
        XCTAssertEqual(empty, [])
    }

    // MARK: - Branch CRUD

    func testBranchCRUDAndActivation() async throws {
        let store = makeStore()
        let conv = StoredConversation(title: "branches")
        await store.upsert(conv)
        let root = StoredMessage(conversationID: conv.id, role: .user, content: "root")
        await store.upsert(root)

        let b1 = try await store.upsert(StoredBranch(conversationID: conv.id, parentMessageID: root.id, branchIndex: 0))
        let b2 = try await store.upsert(StoredBranch(conversationID: conv.id, parentMessageID: root.id, branchIndex: 1))
        XCTAssertNotNil(b1.id)
        XCTAssertNotNil(b2.id)

        var list = try await store.branches(conversationID: conv.id)
        XCTAssertEqual(list.map(\.branchIndex), [0, 1])
        XCTAssertEqual(list.filter(\.active).count, 2, "both insert as active")

        // Switching active deactivates all others.
        try await store.setActiveBranch(id: b2.id!, conversationID: conv.id)
        list = try await store.branches(conversationID: conv.id)
        XCTAssertEqual(list.filter(\.active).map(\.id), [b2.id])

        // Delete leaves the sibling untouched.
        try await store.deleteBranch(id: b1.id!)
        list = try await store.branches(conversationID: conv.id)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].id, b2.id)
    }

    // MARK: - Outbox retry/backoff ordering

    func testOutboxBackoffOrdering() {
        // 2^(n+1) capped at 60: attempts 0..5 → 2,4,8,16,32,60 (jitterless).
        let noJitter = [0, 1, 2, 3, 4, 5, 6, 10].map {
            OutboxActor.backoffSeconds(afterAttempt: $0, jitter: 0.5)
        }
        XCTAssertEqual(noJitter, [2, 4, 8, 16, 32, 60, 60, 60])
        // Jitter stays within ±25% of the base.
        for attempt in 0...8 {
            let d = OutboxActor.backoffSeconds(afterAttempt: attempt, jitter: 0.0)
            let base = min(pow(2, Double(attempt + 1)), 60)
            XCTAssertGreaterThanOrEqual(d, base * 0.75 - 0.001)
            XCTAssertLessThanOrEqual(d, base * 1.25 + 0.001)
        }
    }

    func testOutboxDrainRetryBackoffAndAck() async throws {
        let store = makeStore()
        let conv = StoredConversation(title: "outbox")
        await store.upsert(conv)

        // Transport fails the first 2 attempts of entry A, then succeeds.
        actor FlakyTransport {
            var attempts: [UUID: Int] = [:]
            func call(_ e: OutboxEntry) throws {
                attempts[e.id, default: 0] += 1
                if e.payload.body == "fail-twice" && attempts[e.id]! < 3 {
                    throw TransportError.denied
                }
            }
            func count(_ id: UUID) -> Int { attempts[id] ?? 0 }
        }
        enum TransportError: Error { case denied }
        let transport = FlakyTransport()

        let t0 = 1_000.0
        var clock = t0
        let outbox = OutboxActor(store: store, send: { entry in try transport.call(entry) })

        let a = OutboxEntry(payload: OutboxPayload(kind: "send-message", conversationID: conv.id, body: "fail-twice"),
                            createdAt: Date(timeIntervalSince1970: t0))
        let b = OutboxEntry(payload: OutboxPayload(kind: "send-message", conversationID: conv.id, body: "ok-first"),
                            createdAt: Date(timeIntervalSince1970: t0))
        await store.enqueue(a)
        await store.enqueue(b)

        // Round 1 (t=t0): B acked+removed; A fails → attempts=1, backoff ~4s.
        var sent = try await outbox.drainOnce(now: clock)
        XCTAssertEqual(sent, 1)
        let remaining1 = await store.outboxCount()
        XCTAssertEqual(remaining1, 1)
        let a1 = await store.outboxEntry(id: a.id)
        XCTAssertEqual(a1?.attempts, 1)

        // A not yet due (next_retry_at ≈ t0 + 4s).
        clock = t0 + 1
        sent = try await outbox.drainOnce(now: clock)
        XCTAssertEqual(sent, 0, "must respect backoff window")

        // Advance past backoff: A fails again (attempt 2, backoff 8s).
        clock = t0 + 5
        sent = try await outbox.drainOnce(now: clock)
        XCTAssertEqual(sent, 0)
        let a2 = await store.outboxEntry(id: a.id)
        XCTAssertEqual(a2?.attempts, 2)

        // Third attempt succeeds → entry leaves the queue (ack).
        clock = t0 + 14
        sent = try await outbox.drainOnce(now: clock)
        XCTAssertEqual(sent, 1)
        let remaining2 = await store.outboxCount()
        XCTAssertEqual(remaining2, 0)
        let totalCalls = await transport.count(a.id)
        XCTAssertEqual(totalCalls, 3, "two failures then one success")
    }

    func testOutboxReconnectResetAndOrder() async throws {
        let store = makeStore()
        actor Recorder {
            var order: [String] = []
            func record(_ e: OutboxEntry) { order.append(e.payload.body) }
            func read() -> [String] { order }
        }
        let recorder = Recorder()
        let outbox = OutboxActor(store: store, send: { entry in await recorder.record(entry) })

        let t0 = 500.0
        // Three entries enqueued in order; first two already backoff-scheduled
        // far in the future (simulating earlier failures).
        let e1 = OutboxEntry(payload: OutboxPayload(kind: "send-message", body: "e1"),
                             nextRetryAt: Date(timeIntervalSince1970: t0 + 60),
                             createdAt: Date(timeIntervalSince1970: t0))
        let e2 = OutboxEntry(payload: OutboxPayload(kind: "send-message", body: "e2"),
                             attempts: 3,
                             nextRetryAt: Date(timeIntervalSince1970: t0 + 60),
                             createdAt: Date(timeIntervalSince1970: t0 + 1))
        let e3 = OutboxEntry(payload: OutboxPayload(kind: "send-message", body: "e3"),
                             createdAt: Date(timeIntervalSince1970: t0 + 2))
        await store.enqueue(e1)
        await store.enqueue(e2)
        await store.enqueue(e3)

        // Without reconnect: only e3 is due.
        var sent = try await outbox.drainOnce(now: t0)
        XCTAssertEqual(sent, 1)

        // Reconnect: backoff resets, ALL pending drain immediately, FIFO.
        sent = try await outbox.drainOnReconnect(now: t0 + 61)
        XCTAssertEqual(sent, 2)
        let order = await recorder.read()
        XCTAssertEqual(order, ["e3", "e1", "e2"], "drain must be FIFO by enqueue time")
        let remaining = await store.outboxCount()
        XCTAssertEqual(remaining, 0)
    }

    // MARK: - Widget snapshot (App-Group schema, feature #40 prep)

    func testWidgetSnapshotRoundTrip() async {
        let store = makeStore()
        let entry = WidgetSnapshotEntry(key: "status", valueJSON: #"{"agent":"running"}"#)
        let before = await store.widgetSnapshotEntry(key: "status")
        XCTAssertNil(before)
        await store.updateWidgetSnapshot(entry)
        let read = await store.widgetSnapshotEntry(key: "status")
        XCTAssertEqual(read?.valueJSON, #"{"agent":"running"}"#)
        // Upsert by key, not append.
        var updated = entry
        updated.valueJSON = #"{"agent":"idle"}"#
        await store.updateWidgetSnapshot(updated)
        let reread = await store.widgetSnapshotEntry(key: "status")
        XCTAssertEqual(reread?.valueJSON, #"{"agent":"idle"}"#)
    }
}
