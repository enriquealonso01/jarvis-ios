import Foundation
import GRDB
import XCTest

@testable import Persistence

final class PersistenceTests: XCTestCase {
    func testMigrationChainValidator() {
        XCTAssertTrue(Schema.isWellOrdered([
            Migration(identifier: "a", order: 1),
            Migration(identifier: "b", order: 2),
        ]))
        XCTAssertFalse(Schema.isWellOrdered([
            Migration(identifier: "b", order: 2),
            Migration(identifier: "a", order: 1),
        ]))
        // duplicate identifiers = not well-ordered
        XCTAssertFalse(Schema.isWellOrdered([
            Migration(identifier: "a", order: 1),
            Migration(identifier: "a", order: 2),
        ]))
        XCTAssertTrue(Schema.isWellOrdered(Schema.migrations))
    }

    func testStoreUpsertGet() async {
        let store = PersistenceStore()
        let conv = StoredConversation(title: "Krendora orders")
        store.upsert(conv)
        let fetched = await store.get(id: conv.id)
        XCTAssertEqual(fetched, conv)
        let count = await store.count()
        XCTAssertEqual(count, 1)
    }

    // MARK: Schema v1 (GRDB)

    func makeStore() throws -> PersistenceStore {
        try PersistenceStore(inMemory: true)
    }

    func testV1MigrationRunsAndTablesExist() throws {
        // A fresh store migrates cleanly; the v1 tables + FTS index exist.
        let store = try makeStore()
        let conv = StoredConversation(title: "schema")
        try store.upsertConv(conv)
        XCTAssertEqual(try store.countConversations(), 1)
        // Message insert exercises the FK + FTS triggers end to end.
        let message = StoredMessage(conversationID: conv.id, role: .user, content: "hello world")
        try store.upsert(message)
        XCTAssertEqual(try store.messageCount(conversationID: conv.id), 1)
    }

    func testMessagePagination() throws {
        let store = try makeStore()
        let conv = StoredConversation(title: "pagination")
        try store.upsertConv(conv)
        let base = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<120 {
            try store.upsert(StoredMessage(
                conversationID: conv.id,
                role: i.isMultiple(of: 2) ? .user : .assistant,
                content: "msg \(i)",
                createdAt: base.addingTimeInterval(Double(i))
            ))
        }
        XCTAssertEqual(try store.messageCount(conversationID: conv.id), 120)

        let page0 = try store.fetchMessages(conversationID: conv.id, page: 0)
        let page1 = try store.fetchMessages(conversationID: conv.id, page: 1)
        let page2 = try store.fetchMessages(conversationID: conv.id, page: 2)
        XCTAssertEqual(page0.count, 50, "page size must be 50")
        XCTAssertEqual(page1.count, 50)
        XCTAssertEqual(page2.count, 20)
        XCTAssertEqual(page0.first?.content, "msg 0", "oldest message first")
        XCTAssertEqual(page1.first?.content, "msg 50", "pages advance without overlap")
        XCTAssertEqual(page2.last?.content, "msg 119", "newest message last")
        // Default page size constant is the pinned contract.
        XCTAssertEqual(PersistenceStore.messagePageSize, 50)
    }

    func testUpsertMessageUpdatesConversationPreview() throws {
        let store = try makeStore()
        let conv = StoredConversation(title: "preview")
        try store.upsertConv(conv)
        try store.upsert(StoredMessage(conversationID: conv.id, role: .user, content: String(repeating: "x", count: 300)))
        let fetched = try store.getConv(id: conv.id)
        XCTAssertEqual(fetched?.lastMessagePreview?.count, 120, "preview truncates at 120 chars")
    }

    func testMessageStatusRoundTripAndPartialUpdate() throws {
        let store = try makeStore()
        let conv = StoredConversation(title: "status")
        try store.upsertConv(conv)
        let message = StoredMessage(conversationID: conv.id, role: .assistant, content: "streaming…", status: .streaming)
        try store.upsert(message)
        try store.updateMessage(id: message.id, status: .sent, serverID: "srv_1")
        let fetched = try store.get(id: message.id)
        XCTAssertEqual(fetched?.status, .sent)
        XCTAssertEqual(fetched?.serverID, "srv_1")
        XCTAssertEqual(fetched?.content, "streaming…", "partial update must not clobber content")
        // Raw enum values stored as strings.
        XCTAssertEqual(MessageStatus.allCases.map(\.rawValue), ["sending", "sent", "failed", "streaming"])
    }

    func testAttachmentsJSONRoundTrip() throws {
        let store = try makeStore()
        let conv = StoredConversation(title: "attachments")
        try store.upsertConv(conv)
        let attachments = [
            StoredAttachment(kind: "image", name: "photo.jpg", localPath: "/tmp/p.jpg"),
            StoredAttachment(kind: "file", name: "invoice.pdf"),
        ]
        try store.upsert(StoredMessage(conversationID: conv.id, role: .user, content: "see attached", attachments: attachments))
        let fetched = try store.get(id: store.fetchMessages(conversationID: conv.id, page: 0).first!.id)
        XCTAssertEqual(fetched?.attachments, attachments)
    }

    func testOutboxEnqueueAckRetryBackoff() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.outboxCount(), 0)

        let entry = try store.enqueue(OutboxPayload(kind: "send-message", body: "hi"))
        XCTAssertNotNil(entry.id)
        XCTAssertEqual(try store.outboxCount(), 1)

        // Immediately due (nextRetryAt defaults to now).
        var due = try store.dueOutbox()
        XCTAssertEqual(due.count, 1)
        XCTAssertEqual(due.first?.payload.kind, "send-message")

        // Ack removes it.
        try store.ack(id: entry.id!)
        XCTAssertEqual(try store.outboxCount(), 0)
        due = try store.dueOutbox()
        XCTAssertTrue(due.isEmpty, "acked entries must leave the queue")

        // Retry path: exponential backoff 2^attempts, capped at 60s.
        let failing = try store.enqueue(OutboxPayload(kind: "send-message", body: "retry me"))
        var current = failing
        for attempt in 1...7 {
            try store.retry(id: current.id!)
            let expected = min(pow(2.0, Double(attempt)), 60)
            // After the nth retry, the entry is not due for ~2^n seconds.
            let notYetDue = try store.dueOutbox(now: Date()).filter { $0.id == current.id }
            XCTAssertTrue(notYetDue.isEmpty, "attempt \(attempt): entry must be in backoff")
            // It becomes due again after the backoff window.
            let later = Date().addingTimeInterval(expected + 1)
            let dueAgain = try store.dueOutbox(now: later).filter { $0.id == current.id }
            XCTAssertEqual(dueAgain.count, 1, "attempt \(attempt): entry due after ~\(expected)s backoff")
            current = dueAgain[0]
        }
        // Attempts incremented along the way.
        XCTAssertGreaterThanOrEqual(current.attempts, 7)
        // Cap: the 8th retry schedules at most 60s out even though 2^8 > 60.
        try store.retry(id: current.id!)
        let capped = try store.dueOutbox(now: Date().addingTimeInterval(61)).filter { $0.id == current.id }
        XCTAssertEqual(capped.count, 1, "backoff must cap at 60s")
        let notCapped = try store.dueOutbox(now: Date().addingTimeInterval(30)).filter { $0.id == current.id }
        XCTAssertTrue(notCapped.isEmpty, "capped backoff must still be > 30s")
        // Unknown id retry is a no-op.
        XCTAssertNil(try store.retry(id: 99_999))
    }

    func testOutboxDueOrderingOldestFirst() throws {
        let store = try makeStore()
        let old = try store.enqueue(OutboxPayload(kind: "a", body: "old"))
        _ = try store.enqueue(OutboxPayload(kind: "b", body: "new"))
        let due = try store.dueOutbox()
        XCTAssertEqual(due.first?.id, old.id, "oldest entry drains first")
    }

    func testBranchCRUDAndSingleActive() throws {
        let store = try makeStore()
        let conv = StoredConversation(title: "branches")
        try store.upsertConv(conv)
        let rootMessage = StoredMessage(conversationID: conv.id, role: .user, content: "root")
        try store.upsert(rootMessage)
        let replyMessage = StoredMessage(conversationID: conv.id, role: .assistant, content: "answer v1")
        try store.upsert(replyMessage)

        let b1 = try store.insertBranch(StoredBranch(conversationID: conv.id, parentMessageID: rootMessage.id, branchIndex: 0))
        let b2 = try store.insertBranch(StoredBranch(conversationID: conv.id, parentMessageID: rootMessage.id, branchIndex: 1))
        XCTAssertNotNil(b1.id)
        XCTAssertNotNil(b2.id)
        XCTAssertEqual(try store.fetchBranches(conversationID: conv.id).count, 2)

        // Single-active rule: activating b2 deactivates b1.
        try store.setActiveBranch(id: b2.id!, conversationID: conv.id)
        let branches = try store.fetchBranches(conversationID: conv.id)
        XCTAssertEqual(branches.first { $0.id == b1.id }?.active, false)
        XCTAssertEqual(branches.first { $0.id == b2.id }?.active, true)

        try store.deleteBranch(id: b1.id!)
        XCTAssertEqual(try store.fetchBranches(conversationID: conv.id).count, 1)
        // Deleting the parent message doesn't cascade-delete branches (they
        // reference conversations only) — the row just keeps a dangling parent.
        try store.deleteMessageForTest(replyMessage.id)
        XCTAssertEqual(try store.fetchBranches(conversationID: conv.id).count, 1)
    }

    func testRunCardsCRUD() throws {
        let store = try makeStore()
        let conv = StoredConversation(title: "runs")
        try store.upsertConv(conv)
        let card = RunCard(
            conversationID: conv.id,
            runID: "run_42",
            status: .running,
            steps: [RunStep(title: "Fetch orders", done: true), RunStep(title: "Summarize")]
        )
        try store.upsert(card)
        var fetched = try store.fetchRunCards(conversationID: conv.id)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.status, .running)
        XCTAssertEqual(fetched.first?.steps.count, 2)

        var done = card
        done.status = .done
        try store.upsert(done)
        fetched = try store.fetchRunCards(conversationID: conv.id)
        XCTAssertEqual(fetched.count, 1, "upsert must not duplicate run cards")
        XCTAssertEqual(fetched.first?.status, .done)
    }

    func testFTS5Search() throws {
        let store = try makeStore()
        let conv = StoredConversation(title: "search")
        try store.upsertConv(conv)
        try store.upsert(StoredMessage(conversationID: conv.id, role: .user, content: "Krendora orders report for October"))
        try store.upsert(StoredMessage(conversationID: conv.id, role: .assistant, content: "Summary of the Krendora October numbers"))
        try store.upsert(StoredMessage(conversationID: conv.id, role: .user, content: "totally unrelated content"))

        let hits = try store.searchMessages("Krendora")
        XCTAssertEqual(hits.count, 2, "FTS must find both matching messages")
        XCTAssertTrue(hits.contains { $0.message.content.contains("report") })
        XCTAssertFalse(hits.contains { $0.message.content.contains("unrelated") })

        // Prefix search (FTS5 implicit prefix at query time via *).
        XCTAssertEqual(try store.searchMessages("Krend*").count, 2)
        // No hits → empty; empty query → empty (never a crash).
        XCTAssertEqual(try store.searchMessages("zebra").count, 0)
        XCTAssertEqual(try store.searchMessages("").count, 0)
        // Snippets are populated.
        XCTAssertTrue(try store.searchMessages("October").allSatisfy { !$0.snippet.isEmpty })
    }

    func testWidgetSnapshotTable() throws {
        let store = try makeStore()
        XCTAssertNil(try store.readSnapshot(key: "status"))
        try store.writeSnapshot(WidgetSnapshotEntry(key: "status", valueJSON: #"{"online":true}"#))
        let entry = try store.readSnapshot(key: "status")
        XCTAssertEqual(entry?.valueJSON, #"{"online":true}"#)
        // Upsert by key, not append.
        try store.writeSnapshot(WidgetSnapshotEntry(key: "status", valueJSON: #"{"online":false}"#))
        let updated = try store.readSnapshot(key: "status")
        XCTAssertEqual(updated?.valueJSON, #"{"online":false}"#)
    }

    func testCascadeDeleteRemovesMessagesAndBranches() throws {
        let store = try makeStore()
        let conv = StoredConversation(title: "cascade")
        try store.upsertConv(conv)
        try store.upsert(StoredMessage(conversationID: conv.id, role: .user, content: "one"))
        _ = try store.insertBranch(StoredBranch(conversationID: conv.id))
        try store.upsert(RunCard(conversationID: conv.id, runID: "r", status: .queued))

        try store.delete(id: conv.id)
        XCTAssertEqual(try store.messageCount(conversationID: conv.id), 0)
        XCTAssertEqual(try store.fetchBranches(conversationID: conv.id).count, 0)
        XCTAssertEqual(try store.fetchRunCards(conversationID: conv.id).count, 0)
    }
}

extension PersistenceStore {
    /// Test hook: delete one message without widening the public API.
    func deleteMessageForTest(_ id: UUID) throws {
        try deleteMessageInternal(id: id)
    }

    func deleteMessageInternal(id: UUID) throws {
        try dbQueue.write { db in
            _ = try StoredMessage.deleteOne(db, key: id.uuidString)
        }
    }
}
