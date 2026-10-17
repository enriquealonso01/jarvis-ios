import Foundation
import XCTest

@testable import Persistence

/// Item 1 FIXER (attempt 1): §5.2 completeness pins. Fresh migration from an
/// empty store must expose the five v2 tables (projects, runs, run_steps,
/// recordings, transcript_segments) through the public store API; messages
/// must persist serverId + pendingSync; transcript_segments must be FTS5-
/// searchable.
final class Item1V2SchemaTests: XCTestCase {

    private func tempDBPath(_ label: String) -> String {
        let dir = NSTemporaryDirectory() + "item1-v2-\(label)-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/store.sqlite"
    }

    // MARK: - migrations-from-empty covers the new tables

    func testV2MigrationsFromEmptyExposeNewTables() async throws {
        let store = try PersistenceStore(path: tempDBPath("from-empty"))
        // Whole-second convention (pinned repo-wide): unix-second REAL storage
        // is bit-exact only for whole-second dates (same as Item 0/1 pins).
        let stamp = Date(timeIntervalSince1970: 1_760_000_000)

        // projects
        let project = StoredProject(
            name: "Krendora", instructions: "tone: dry", updatedAt: stamp)
        await store.upsert(project)
        let fetchedProject = await store.getProject(id: project.id)
        XCTAssertEqual(fetchedProject, project, "projects must exist and round-trip")

        // runs (conversation ref)
        let conv = StoredConversation(title: "v2 schema", updatedAt: stamp)
        await store.upsert(conv)
        let run = StoredRun(conversationID: conv.id, status: .running, updatedAt: stamp)
        await store.upsert(run)
        let fetchedRun = await store.getRun(id: run.id)
        XCTAssertEqual(fetchedRun, run, "runs must exist and round-trip")

        // run_steps (run ref, title, order)
        let step = StoredRunStep(runID: run.id, title: "Draft reply", stepOrder: 2)
        _ = await store.addRunStep(step)
        let steps = await store.runSteps(runID: run.id)
        XCTAssertEqual(steps.count, 1, "run_steps must exist and accept rows")
        XCTAssertEqual(steps.first?.title, "Draft reply")
        XCTAssertEqual(steps.first?.stepOrder, 2)
        XCTAssertEqual(steps.first?.state, .pending)
        XCTAssertNotNil(steps.first?.id, "auto-increment id must be assigned")

        // recordings (file ref, duration)
        let recording = StoredRecording(
            filePath: "recordings/a.m4a", duration: 12.5, updatedAt: stamp)
        _ = await store.upsert(recording)
        let fetchedRecording = await store.getRecording(id: recording.id)
        XCTAssertEqual(fetchedRecording, recording, "recordings must exist and round-trip")

        // transcript_segments (recording ref, speaker, text)
        let segment = StoredTranscriptSegment(
            recordingID: recording.id, speaker: "agent", text: "Refund issued")
        _ = await store.addTranscriptSegment(segment)
        let segments = await store.transcriptSegments(recordingID: recording.id)
        XCTAssertEqual(segments, [segment], "transcript_segments must exist and round-trip")
    }

    // MARK: - serverId + pendingSync round-trip

    func testServerIDAndPendingSyncRoundTrip() async throws {
        let store = PersistenceStore()
        let conv = StoredConversation(title: "sync columns")
        await store.upsert(conv)

        // Default: no server ID, pendingSync true (outbox contract).
        let message = StoredMessage(conversationID: conv.id, role: .user, content: "ping")
        await store.upsert(message)
        var fetched = await store.getMessage(id: message.id)
        XCTAssertNil(fetched?.serverID, "unset serverId must persist as nil")
        XCTAssertEqual(fetched?.pendingSync, true, "new messages start pendingSync=true")
        let pending = await store.pendingSyncMessages(conversationID: conv.id)
        XCTAssertEqual(pending.map(\.id), [message.id])

        // ACK: serverId stamped + pendingSync cleared, both persisted.
        let serverID = "srv_\(message.id.uuidString.prefix(8))"
        let acked = await store.markMessageSynced(id: message.id, serverID: serverID)
        XCTAssertEqual(acked?.serverID, serverID)
        XCTAssertEqual(acked?.pendingSync, false)

        fetched = await store.getMessage(id: message.id)
        XCTAssertEqual(fetched?.serverID, serverID, "serverId must round-trip from disk")
        XCTAssertEqual(fetched?.pendingSync, false, "pendingSync must round-trip from disk")

        // Server-ID lookup + queue-empty after ACK.
        let byServer = await store.getMessage(serverID: serverID)
        XCTAssertEqual(byServer?.id, message.id)
        let stillPending = await store.pendingSyncMessages(conversationID: conv.id)
        XCTAssertTrue(stillPending.isEmpty, "ACKed messages leave the pending queue")
    }

    func testServerIDUniqueness() async throws {
        let store = PersistenceStore()
        let conv = StoredConversation(title: "server id unique")
        await store.upsert(conv)

        let first = StoredMessage(conversationID: conv.id, role: .user, content: "one")
        let second = StoredMessage(conversationID: conv.id, role: .user, content: "two")
        await store.upsert(first)
        await store.upsert(second)
        _ = await store.markMessageSynced(id: first.id, serverID: "srv_dup")

        // The unique index on server_id must reject a duplicate stamp.
        let conflict = await store.markMessageSynced(id: second.id, serverID: "srv_dup")
        XCTAssertNil(conflict, "duplicate serverId must violate the unique index")
        let loser = await store.getMessage(id: second.id)
        XCTAssertNil(loser?.serverID, "rejected stamp must not mutate the row")
    }

    // MARK: - transcript_segments FTS query

    func testTranscriptSegmentsFTSQuery() async throws {
        let store = PersistenceStore()
        let recording = StoredRecording(filePath: "recordings/q.m4a", duration: 30)
        _ = await store.upsert(recording)
        _ = await store.addTranscriptSegment(
            StoredTranscriptSegment(recordingID: recording.id, speaker: "agent",
                                    text: "The refund was issued this morning"))
        _ = await store.addTranscriptSegment(
            StoredTranscriptSegment(recordingID: recording.id, speaker: "user",
                                    text: "What about the shipping label?"))
        _ = await store.addTranscriptSegment(
            StoredTranscriptSegment(recordingID: recording.id, speaker: "agent",
                                    text: "Label sent to your email"))

        // Index must be populated by the FTS5 sync triggers, rank-ordered.
        let hits = try await store.searchTranscriptSegments(matching: "refund")
        XCTAssertEqual(hits.count, 1, "synchronized FTS must see inserted segments")
        XCTAssertEqual(hits.first?.text, "The refund was issued this morning")
        XCTAssertEqual(hits.first?.speaker, "agent")

        let labels = try await store.searchTranscriptSegments(matching: "shipping")
        XCTAssertEqual(labels.count, 1)
        XCTAssertEqual(labels.first?.speaker, "user")

        // Empty index queries cleanly (virtual table exists from migration).
        let fresh = try PersistenceStore(path: tempDBPath("fts-empty"))
        let none = try await fresh.searchTranscriptSegments(matching: "anything")
        XCTAssertTrue(none.isEmpty, "transcript_segments_fts must exist and query cleanly when empty")
    }

    // MARK: - migration-chain contract still holds

    func testV2MigrationsAppendWellOrdered() {
        XCTAssertEqual(Schema.Migrations.v2ProjectsRuns.order, 4)
        XCTAssertEqual(Schema.Migrations.v2MessageSyncColumns.order, 5)
        XCTAssertEqual(Schema.Migrations.v2FTSTranscripts.order, 6)
        XCTAssertTrue(Schema.isWellOrdered(Schema.migrations))
        // v1 history untouched.
        XCTAssertEqual(Schema.migrations.prefix(3), [
            Schema.Migrations.v1, Schema.Migrations.v1FTS, Schema.Migrations.v1WidgetSnapshot,
        ])
    }
}
