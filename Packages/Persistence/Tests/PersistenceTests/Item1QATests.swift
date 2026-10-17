import Foundation
import XCTest

@testable import Persistence

/// Item 1 TESTER QA (feature #4 persistence correctness) — independent of the
/// builder's own PersistenceTests.swift. Covers the five QA scope areas:
///   1. Migration runs clean on a fresh DB; re-init (re-run) is idempotent;
///      FTS index is populated after message inserts.
///   2. Conversation/message CRUD + the 50-per-page pagination boundary
///      (137 messages → pages of 50/50/37, order + count asserted).
///   3. Outbox: enqueue → ack removes; a failed attempt increments `attempts`
///      and schedules growing backoff (`next_retry_at`); crash recovery —
///      rows survive store re-init on the same file.
///   4. Branch CRUD: create, switch active, prior turns stay retrievable.
///   5. Widget-snapshot table readable through an App-Group path simulation
///      (temp-dir file DB standing in for the real App Group container).
/// Pure GRDB logic — no UIKit, runnable via `swift test` and CI xcodebuild.
final class Item1QATests: XCTestCase {

    // MARK: - Helpers

    private func tempDBPath(_ label: String) -> String {
        let dir = NSTemporaryDirectory() + "item1-qa-\(label)-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            ofType: .directory, atPath: dir, withIntermediateDirectories: true
        )
        return dir + "/store.sqlite"
    }

    private func makeMessage(_ i: Int, in conversationID: UUID, base: Date) -> StoredMessage {
        StoredMessage(
            conversationID: conversationID,
            role: i.isMultiple(of: 2) ? .user : .assistant,
            content: "qa msg \(i)",
            status: .sent,
            createdAt: base.addingTimeInterval(Double(i))
        )
    }

    // MARK: 1. Migration: fresh DB clean, re-run idempotent, FTS populated

    func testMigrationFreshDBRunsClean() async {
        // PersistenceStore() runs the full migration chain in init; a clean,
        // non-failing init on a fresh in-memory DB is the "runs clean" proof.
        let store = PersistenceStore()
        let conversations = await store.count()
        XCTAssertEqual(conversations, 0, "fresh DB must have zero conversations")
        let outbox = await store.outboxCount()
        XCTAssertEqual(outbox, 0, "fresh DB must have zero outbox rows")

        // Every core table is exercisable right after migration.
        let conv = StoredConversation(title: "migration fresh")
        await store.upsert(conv)
        await store.upsert(StoredMessage(
            conversationID: conv.id, role: .user, content: "post-migration insert"
        ))
        let total = await store.messageCount(conversationID: conv.id)
        XCTAssertEqual(total, 1, "message insert must succeed immediately after migration")
    }

    func testMigrationRerunIsIdempotentViaStoreReinit() async throws {
        // Re-running the migrator on an already-migrated DB (a second store
        // instance over the same file) must succeed without altering data —
        // the GRDB definition of idempotent.
        let path = tempDBPath("idempotent")
        let first = try PersistenceStore(path: path)
        let conv = StoredConversation(title: "idempotent re-run")
        await first.upsert(conv)
        await first.upsert(StoredMessage(
            conversationID: conv.id, role: .user, content: "survives re-migration"
        ))

        let second = try PersistenceStore(path: path) // migrator re-runs, no-ops
        let count = await second.count()
        XCTAssertEqual(count, 1, "re-migration must not duplicate or drop rows")
        let fetched = await second.get(id: conv.id)
        XCTAssertEqual(fetched?.title, "idempotent re-run")
        let messages = try await second.messages(conversationID: conv.id)
        XCTAssertEqual(messages.count, 1)
        let outbox = await second.outboxCount()
        XCTAssertEqual(outbox, 0, "re-migration must not fabricate outbox rows")
    }

    func testFTSIndexPopulatedAfterMessageInserts() async throws {
        let store = PersistenceStore()
        let conv = StoredConversation(title: "fts qa")
        await store.upsert(conv)

        let needle = StoredMessage(
            conversationID: conv.id, role: .user,
            content: "xylophone quartet rehearsal notes"
        )
        await store.upsert(StoredMessage(
            conversationID: conv.id, role: .user, content: "unrelated filler text"
        ))
        await store.upsert(needle)

        // The FTS index must reflect inserted rows immediately.
        let hits = try await store.searchMessages(matching: "xylophone")
        XCTAssertEqual(hits.count, 1, "FTS must surface the inserted row")
        XCTAssertEqual(hits.first?.id, needle.id)

        // A token from the other row resolves too — index covers all inserts.
        let filler = try await store.searchMessages(matching: "filler")
        XCTAssertEqual(filler.count, 1)
    }

    // MARK: 2. CRUD + 137-message pagination boundary

    func testConversationMessageCRUD() async throws {
        let store = PersistenceStore()

        // Create.
        let conv = StoredConversation(title: "crud", lastMessagePreview: nil)
        await store.upsert(conv)
        XCTAssertEqual(await store.count(), 1)

        // Message create + read.
        let m = StoredMessage(conversationID: conv.id, role: .user, content: "hello qa")
        await store.upsert(m)
        let fetched = try await store.messages(conversationID: conv.id)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.id, m.id)
        XCTAssertEqual(fetched.first?.content, "hello qa")
        let byID = await store.getMessage(id: m.id)
        XCTAssertEqual(byID?.content, "hello qa")

        // Update (same id replaces) + conversation preview touch.
        var edited = m
        edited.content = "hello qa — edited"
        await store.upsert(edited)
        let afterEdit = try await store.messages(conversationID: conv.id)
        XCTAssertEqual(afterEdit.count, 1, "upsert must not append rows")
        XCTAssertEqual(afterEdit.first?.content, "hello qa — edited")
        let touched = await store.get(id: conv.id)
        XCTAssertEqual(touched?.lastMessagePreview, "hello qa — edited")

        // Delete: message removal, then conversation removal.
        try await store.deleteMessageForTest(id: m.id)
        let afterDelete = try await store.messages(conversationID: conv.id)
        XCTAssertEqual(afterDelete.count, 0)
        let removed = await store.deleteConversation(id: conv.id)
        XCTAssertTrue(removed)
        XCTAssertEqual(await store.count(), 0)
        let orphaned = await store.getMessage(id: m.id)
        XCTAssertNil(orphaned)
    }

    func testPagination137MessagesFiftyPerPage() async throws {
        let store = PersistenceStore()
        let conv = StoredConversation(title: "pagination 137")
        await store.upsert(conv)

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<137 {
            await store.upsert(makeMessage(i, in: conv.id, base: base))
        }
        let total = await store.messageCount(conversationID: conv.id)
        XCTAssertEqual(total, 137, "all 137 inserts must land")

        // Page through: 50 + 50 + 37, then an empty page past the end.
        var paged: [StoredMessage] = []
        var page = 0
        while true {
            let chunk = try await store.fetchMessages(conversationID: conv.id, page: page)
            if chunk.isEmpty { break }
            XCTAssertLessThanOrEqual(chunk.count, 50, "page \(page) exceeds page size")
            paged.append(contentsOf: chunk)
            page += 1
            XCTAssertLessThan(page, 10, "runaway pagination loop guard")
        }
        XCTAssertEqual(paged.count, 137, "paged traversal must cover every message exactly once")
        XCTAssertEqual(page, 3, "137 messages = exactly 3 pages (50/50/37)")
        XCTAssertEqual(paged[0].content, "qa msg 0", "oldest message first")
        XCTAssertEqual(paged[136].content, "qa msg 136", "newest message last")
        XCTAssertEqual(paged[49].content, "qa msg 49", "page 0 boundary")
        XCTAssertEqual(paged[50].content, "qa msg 50", "page 1 starts without overlap")
        XCTAssertEqual(paged[99].content, "qa msg 99", "page 1 boundary")
        XCTAssertEqual(paged[100].content, "qa msg 100", "page 2 starts without overlap")

        // Strict ordering across the whole traversal.
        let stamps = paged.map { $0.createdAt }
        XCTAssertEqual(stamps, stamps.sorted(), "pages must come back oldest→newest")
        XCTAssertEqual(paged.map { $0.id }, Array(Set(paged.map { $0.id })), "no duplicates across pages")

        // Off-boundary page is empty, not a crash.
        let beyond = try await store.fetchMessages(conversationID: conv.id, page: 3)
        XCTAssertEqual(beyond.count, 0)
    }

    // MARK: 3. Outbox: ack, failed-attempt backoff growth, crash recovery

    func testOutboxAckRemovesEnqueuedEntry() async throws {
        let store = PersistenceStore()
        let acked = OutboxEntry(
            payload: OutboxPayload(kind: "send-message", body: "deliver me"),
            nextRetryAt: Date(timeIntervalSince1970: 100)
        )
        await store.enqueue(acked)
        var count = await store.outboxCount()
        XCTAssertEqual(count, 1, "enqueue must persist exactly one row")

        let outbox = OutboxActor(store: store, send: { _ in }) // always succeeds
        let sent = try await outbox.drainOnce(now: 200)
        XCTAssertEqual(sent, 1, "successful send must ack")
        count = await store.outboxCount()
        XCTAssertEqual(count, 0, "ack must REMOVE the entry from the queue")
        let gone = await store.outboxEntry(id: acked.id)
        XCTAssertNil(gone)
    }

    func testOutboxFailureIncrementsAttemptsAndGrowsBackoff() async throws {
        let store = PersistenceStore()
        enum TransportError: Error { case down }
        let outbox = OutboxActor(store: store, send: { _ in throw TransportError.down })

        let entry = OutboxEntry(
            payload: OutboxPayload(kind: "send-message", body: "failing entry"),
            nextRetryAt: Date(timeIntervalSince1970: 1_000)
        )
        await store.enqueue(entry)

        // Attempt 1 fails at t=1000: attempts=1, backoff = 2^2 = 4s ±25%.
        try await outbox.drainOnce(now: 1_000)
        var after1 = await store.outboxEntry(id: entry.id)
        XCTAssertEqual(after1?.attempts, 1, "failed attempt must increment attempts")
        XCTAssertNotNil(after1)
        let retry1 = after1!.nextRetryAt.timeIntervalSince1970
        XCTAssertGreaterThan(retry1, 1_000, "next_retry_at must move into the future")
        XCTAssertLessThanOrEqual(retry1, 1_000 + 5, "attempt-1 backoff must stay within 4s +25% jitter")

        // Attempt 2 fails at the first retry time: attempts=2, backoff = 2^3 = 8s ±25%.
        try await outbox.drainOnce(now: retry1 + 0.5)
        let after2 = await store.outboxEntry(id: entry.id)
        XCTAssertEqual(after2?.attempts, 2)
        let retry2 = after2!.nextRetryAt.timeIntervalSince1970
        XCTAssertGreaterThan(retry2, retry1, "next_retry_at must grow monotonically")
        // 8s floor (worst-case jitter −25%) clears attempt-1's 5s ceiling.
        XCTAssertGreaterThanOrEqual(retry2, retry1 + 6, "attempt-2 backoff must exceed attempt-1's window")
        // Still queued — failures retain the entry.
        let stillQueued = await store.outboxCount()
        XCTAssertEqual(stillQueued, 1)
    }

    func testOutboxSurvivesStoreReinitCrashRecovery() async throws {
        // Crash simulation: enqueue on a file-backed store, "die" (drop the
        // instance), re-open from disk — pending rows must survive intact.
        let path = tempDBPath("crash")
        let beforeCrash = try PersistenceStore(path: path)
        let pending = OutboxEntry(
            payload: OutboxPayload(
                kind: "send-message",
                conversationID: UUID(),
                messageID: UUID(),
                body: "must survive the crash"
            ),
            attempts: 2,
            nextRetryAt: Date(timeIntervalSince1970: 5_000)
        )
        let ackWillFollow = OutboxEntry(
            payload: OutboxPayload(kind: "send-message", body: "queued pre-crash too"),
            nextRetryAt: Date(timeIntervalSince1970: 5_000)
        )
        await beforeCrash.enqueue(pending)
        await beforeCrash.enqueue(ackWillFollow)
        var queued = await beforeCrash.outboxCount()
        XCTAssertEqual(queued, 2)

        // Store re-init = process restart over the same DB file.
        let afterCrash = try PersistenceStore(path: path)
        queued = await afterCrash.outboxCount()
        XCTAssertEqual(queued, 2, "outbox rows must survive store re-init")

        let recovered = await afterCrash.outboxEntry(id: pending.id)
        XCTAssertNotNil(recovered)
        XCTAssertEqual(recovered?.attempts, 2, "attempt count must survive")
        XCTAssertEqual(recovered?.payload.body, "must survive the crash")
        XCTAssertEqual(recovered?.payload.kind, "send-message")
        XCTAssertEqual(
            recovered?.nextRetryAt.timeIntervalSince1970, 5_000,
            accuracy: 0.001
        )

        // The recovered queue still drains: ack one, fail-and-backoff the other.
        enum TransportError: Error { case down }
        let outbox = OutboxActor(store: afterCrash, send: { entry in
            if entry.payload.body == "must survive the crash" { throw TransportError.down }
        })
        let sent = try await outbox.drainOnce(now: 6_000)
        XCTAssertEqual(sent, 1, "the healthy entry must ack post-recovery")
        queued = await afterCrash.outboxCount()
        XCTAssertEqual(queued, 1)
        let retried = await afterCrash.outboxEntry(id: pending.id)
        XCTAssertEqual(retried?.attempts, 3, "recovered entry continues its retry ladder")
    }

    // MARK: 4. Branch CRUD + prior-turn retrievability

    func testBranchCreateSwitchActiveAndPriorTurnsRetrievable() async throws {
        let store = PersistenceStore()
        let conv = StoredConversation(title: "branch qa")
        await store.upsert(conv)

        // Prior turns on the main line.
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let prior = (0..<4).map { makeMessage($0, in: conv.id, base: base) }
        for m in prior { await store.upsert(m) }

        // Create two branches off the last prior turn.
        let b1 = try await store.upsert(StoredBranch(
            conversationID: conv.id, parentMessageID: prior[3].id, branchIndex: 1, active: false
        ))
        let b2 = try await store.upsert(StoredBranch(
            conversationID: conv.id, parentMessageID: prior[3].id, branchIndex: 2, active: true
        ))
        XCTAssertNotNil(b1.id)
        XCTAssertNotNil(b2.id)

        // Switch active to b1: b2 must deactivate, b1 activate.
        try await store.setActiveBranch(id: b1.id!, conversationID: conv.id)
        let branches = try await store.branches(conversationID: conv.id)
        XCTAssertEqual(branches.count, 2)
        XCTAssertEqual(branches.filter(\\.active).map(\\.id), [b1.id],
                       "exactly the switched-to branch stays active")

        // Prior turns are retrievable regardless of which branch is active.
        let turns = try await store.messages(conversationID: conv.id)
        XCTAssertEqual(turns.count, 4, "switching branches must not touch prior turns")
        XCTAssertEqual(turns.map(\\.content), prior.map(\\.content))
        XCTAssertEqual(
            turns.map { $0.createdAt.timeIntervalSince1970 },
            prior.map { $0.createdAt.timeIntervalSince1970 },
            "prior-turn order must be preserved"
        )
        let stillThere = await store.messageCount(conversationID: conv.id)
        XCTAssertEqual(stillThere, 4)
    }

    // MARK: 5. Widget snapshot via App-Group path simulation

    func testWidgetSnapshotReadableViaAppGroupPathSimulation() async throws {
        // The App Group container is just a shared directory both processes
        // can open; a temp-dir file DB simulates it (app writer + widget reader).
        let sharedPath = tempDBPath("appgroup")

        // App side: write the snapshot.
        let app = try PersistenceStore(path: sharedPath)
        await app.updateWidgetSnapshot(WidgetSnapshotEntry(
            key: "status", valueJSON: "{\"agent\":\"running\",\"runs\":2}"
        ))

        // Widget side: a fresh store instance over the SAME App-Group path
        // must read what the app wrote.
        let widget = try PersistenceStore(path: sharedPath)
        let read = await widget.widgetSnapshotEntry(key: "status")
        XCTAssertNotNil(read, "widget-side store must see the app's snapshot row")
        XCTAssertEqual(read?.valueJSON, "{\"agent\":\"running\",\"runs\":2}")

        // Single-row upsert semantics + write visibility in the other direction.
        var updated = read!
        updated.valueJSON = "{\"agent\":\"idle\",\"runs\":0}"
        await widget.updateWidgetSnapshot(updated)
        let reRead = await app.widgetSnapshotEntry(key: "status")
        XCTAssertEqual(reRead?.valueJSON, "{\"agent\":\"idle\",\"runs\":0}")
        let keyScoped = await app.widgetSnapshotEntry(key: "nonexistent")
        XCTAssertNil(keyScoped)
    }
}
