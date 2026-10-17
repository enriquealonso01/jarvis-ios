import Foundation
import GRDB

/// GRDB schema: table definitions + migrations (plan §5.2).
///
/// Tables: conversations, messages, projects, runs, run_steps, recordings,
/// transcript_segments, widget_snapshot (App-Group denormalized), outbox.
/// FTS5 over message bodies + transcript segment text, kept in sync by
/// SQLite triggers (insert/update/delete) so the index can never drift.
enum AppSchema {
    // Row <-> GRDB column mapping is via Codable with explicit column names.

    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // v1: core tables ------------------------------------------------
        migrator.registerMigration("v2.core-tables") { db in
            try db.create(table: "project") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("serverID", .text)
                t.column("name", .text).notNull()
                t.column("instructions", .text)
                t.column("pendingSync", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "conversation") { t in
                t.column("id", .blob).primaryKey()
                t.column("serverID", .text)
                t.column("projectID", .blob)
                    .references("project", onDelete: .setNull)
                t.column("title", .text).notNull()
                t.column("pendingSync", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "message") { t in
                t.column("id", .blob).primaryKey()
                t.column("serverID", .text)
                t.column("conversationID", .blob).notNull()
                    .references("conversation", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("body", .text).notNull()
                t.column("pendingSync", .boolean).notNull().defaults(to: true)
                t.column("branchID", .text)
                t.column("branchIndex", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "message.byConversation", on: "message",
                          columns: ["conversationID", "createdAt"])
            try db.create(index: "message.pendingSync", on: "message",
                          columns: ["pendingSync"])

            try db.create(table: "run") { t in
                t.column("id", .blob).primaryKey()
                t.column("serverID", .text)
                t.column("conversationID", .blob)
                    .references("conversation", onDelete: .setNull)
                t.column("projectID", .blob)
                    .references("project", onDelete: .setNull)
                t.column("title", .text).notNull()
                t.column("status", .text).notNull()
                t.column("pendingSync", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "runStep") { t in
                t.column("id", .blob).primaryKey()
                t.column("runID", .blob).notNull()
                    .references("run", onDelete: .cascade)
                t.column("index", .integer).notNull()
                t.column("title", .text).notNull()
                t.column("detail", .text)
                t.column("done", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "recording") { t in
                t.column("id", .blob).primaryKey()
                t.column("serverID", .text)
                t.column("conversationID", .blob)
                    .references("conversation", onDelete: .setNull)
                t.column("projectID", .blob)
                    .references("project", onDelete: .setNull)
                t.column("title", .text).notNull()
                t.column("filePath", .text).notNull()
                t.column("durationSeconds", .double).notNull().defaults(to: 0)
                t.column("pendingSync", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "transcriptSegment") { t in
                t.column("id", .blob).primaryKey()
                t.column("recordingID", .blob).notNull()
                    .references("recording", onDelete: .cascade)
                t.column("speaker", .text)
                t.column("text", .text).notNull()
                t.column("startSeconds", .double).notNull().defaults(to: 0)
                t.column("endSeconds", .double).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }
        }

        // v2: FTS5 index + sync triggers ---------------------------------
        migrator.registerMigration("v2.fts5-index") { db in
            try db.create(virtualTable: "messageFTS", using: FTS5()) { t in
                t.synchronize(withTable: "message")
                t.column("body")
            }
            try db.create(virtualTable: "transcriptSegmentFTS", using: FTS5()) { t in
                t.synchronize(withTable: "transcriptSegment")
                t.column("text")
            }
        }

        // v3: App-Group widget snapshot (denormalized, single row) -------
        migrator.registerMigration("v2.widget-snapshot") { db in
            try db.create(table: "widgetSnapshot") { t in
                t.column("id", .integer).primaryKey().defaults(to: 1)
                t.column("agentStatus", .text).notNull().defaults(to: "offline")
                t.column("activeRuns", .integer).notNull().defaults(to: 0)
                t.column("lastReply", .text)
                t.column("lastReplyConversationID", .blob)
                t.column("updatedAt", .datetime).notNull()
            }
        }

        // v4: outbox queue ------------------------------------------------
        migrator.registerMigration("v2.outbox") { db in
            try db.create(table: "outbox") { t in
                t.column("id", .blob).primaryKey()
                t.column("kind", .text).notNull()
                t.column("payload", .jsonObject).notNull()
                t.column("attempt", .integer).notNull().defaults(to: 0)
                t.column("nextAttemptAt", .double).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(index: "outbox.nextAttempt", on: "outbox",
                          columns: ["nextAttemptAt"])
        }

        return migrator
    }
}

// MARK: - GRDB row wrappers (internal; map to/from Sendable snapshots)

struct ConversationRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "conversation"

    var id: UUID
    var serverID: String?
    var projectID: UUID?
    var title: String
    var pendingSync: Bool
    var createdAt: Date
    var updatedAt: Date

    var snapshot: StoredConversation {
        StoredConversation(
            id: id, serverID: serverID, projectID: projectID, title: title,
            pendingSync: pendingSync, createdAt: createdAt, updatedAt: updatedAt
        )
    }

    init(_ s: StoredConversation) {
        id = s.id
        serverID = s.serverID
        projectID = s.projectID
        title = s.title
        pendingSync = s.pendingSync
        createdAt = s.createdAt
        updatedAt = s.updatedAt
    }

    mutating func didInsert(_: InsertionSuccess) {}
}

struct MessageRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "message"

    var id: UUID
    var serverID: String?
    var conversationID: UUID
    var role: String
    var body: String
    var pendingSync: Bool
    var branchID: String?
    var branchIndex: Int
    var createdAt: Date

    var snapshot: StoredMessage {
        StoredMessage(
            id: id, serverID: serverID, conversationID: conversationID,
            role: StoredMessage.Role(rawValue: role) ?? .assistant, body: body,
            pendingSync: pendingSync, branchID: branchID,
            branchIndex: branchIndex, createdAt: createdAt
        )
    }

    init(_ s: StoredMessage) {
        id = s.id
        serverID = s.serverID
        conversationID = s.conversationID
        role = s.role.rawValue
        body = s.body
        pendingSync = s.pendingSync
        branchID = s.branchID
        branchIndex = s.branchIndex
        createdAt = s.createdAt
    }
}

struct ProjectRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "project"

    var id: Int64?
    var serverID: String?
    var name: String
    var instructions: String?
    var pendingSync: Bool
    var createdAt: Date
    var updatedAt: Date

    init(_ s: StoredProject, id: Int64?) {
        self.id = id
        serverID = s.serverID
        name = s.name
        instructions = s.instructions
        pendingSync = s.pendingSync
        createdAt = s.createdAt
        updatedAt = s.updatedAt
    }

    var snapshotID: UUID? {
        // Project rows use an auto-increment id; snapshots carry a UUID the
        // app generates. We derive a stable UUID from the row id.
        guard let id else { return nil }
        return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012llX", id))
    }

    func snapshot() -> StoredProject {
        StoredProject(
            id: snapshotID ?? UUID(), serverID: serverID, name: name,
            instructions: instructions, pendingSync: pendingSync,
            createdAt: createdAt, updatedAt: updatedAt
        )
    }

    mutating func didInsert(_: InsertionSuccess) {
        self.id = 0
    }
}

struct RunRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "run"

    var id: UUID
    var serverID: String?
    var conversationID: UUID?
    var projectID: UUID?
    var title: String
    var status: String
    var pendingSync: Bool
    var createdAt: Date
    var updatedAt: Date

    init(_ s: StoredRun) {
        id = s.id
        serverID = s.serverID
        conversationID = s.conversationID
        projectID = s.projectID
        title = s.title
        status = s.status.rawValue
        pendingSync = s.pendingSync
        createdAt = s.createdAt
        updatedAt = s.updatedAt
    }

    var snapshot: StoredRun {
        StoredRun(
            id: id, serverID: serverID, conversationID: conversationID,
            projectID: projectID, title: title,
            status: StoredRun.Status(rawValue: status) ?? .queued,
            pendingSync: pendingSync, createdAt: createdAt, updatedAt: updatedAt
        )
    }
}

struct RunStepRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "runStep"

    var id: UUID
    var runID: UUID
    var index: Int
    var title: String
    var detail: String?
    var done: Bool
    var createdAt: Date

    init(_ s: StoredRunStep) {
        id = s.id
        runID = s.runID
        index = s.index
        title = s.title
        detail = s.detail
        done = s.done
        createdAt = s.createdAt
    }

    var snapshot: StoredRunStep {
        StoredRunStep(id: id, runID: runID, index: index, title: title,
                      detail: detail, done: done, createdAt: createdAt)
    }
}

struct RecordingRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "recording"

    var id: UUID
    var serverID: String?
    var conversationID: UUID?
    var projectID: UUID?
    var title: String
    var filePath: String
    var durationSeconds: Double
    var pendingSync: Bool
    var createdAt: Date

    init(_ s: StoredRecording) {
        id = s.id
        serverID = s.serverID
        conversationID = s.conversationID
        projectID = s.projectID
        title = s.title
        filePath = s.filePath
        durationSeconds = s.durationSeconds
        pendingSync = s.pendingSync
        createdAt = s.createdAt
    }

    var snapshot: StoredRecording {
        StoredRecording(
            id: id, serverID: serverID, conversationID: conversationID,
            projectID: projectID, title: title, filePath: filePath,
            durationSeconds: durationSeconds, pendingSync: pendingSync,
            createdAt: createdAt
        )
    }
}

struct TranscriptSegmentRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "transcriptSegment"

    var id: UUID
    var recordingID: UUID
    var speaker: String?
    var text: String
    var startSeconds: Double
    var endSeconds: Double
    var createdAt: Date

    init(_ s: StoredTranscriptSegment) {
        id = s.id
        recordingID = s.recordingID
        speaker = s.speaker
        text = s.text
        startSeconds = s.startSeconds
        endSeconds = s.endSeconds
        createdAt = s.createdAt
    }

    var snapshot: StoredTranscriptSegment {
        StoredTranscriptSegment(
            id: id, recordingID: recordingID, speaker: speaker, text: text,
            startSeconds: startSeconds, endSeconds: endSeconds, createdAt: createdAt
        )
    }
}

struct WidgetSnapshotRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "widgetSnapshot"

    var id: Int64
    var agentStatus: String
    var activeRuns: Int
    var lastReply: String?
    var lastReplyConversationID: UUID?
    var updatedAt: Date

    init(_ s: WidgetSnapshot) {
        id = 1
        agentStatus = s.agentStatus
        activeRuns = s.activeRuns
        lastReply = s.lastReply
        lastReplyConversationID = s.lastReplyConversationID
        updatedAt = s.updatedAt
    }

    var snapshot: WidgetSnapshot {
        WidgetSnapshot(
            agentStatus: agentStatus, activeRuns: activeRuns,
            lastReply: lastReply, lastReplyConversationID: lastReplyConversationID,
            updatedAt: updatedAt
        )
    }
}

struct OutboxEntryRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "outbox"

    var id: UUID
    var kind: String
    var payload: [String: String]
    var attempt: Int
    var nextAttemptAt: Double
    var createdAt: Date

    init(_ e: OutboxEntry) {
        id = e.id
        kind = e.kind.rawValue
        payload = e.payload
        attempt = e.attempt
        nextAttemptAt = e.nextAttemptAt
        createdAt = e.createdAt
    }

    var entry: OutboxEntry {
        OutboxEntry(
            id: id, kind: OutboxEntry.Kind(rawValue: kind) ?? .sendMessage,
            payload: payload, attempt: attempt,
            nextAttemptAt: nextAttemptAt, createdAt: createdAt
        )
    }
}
