import Foundation
import GRDB

// MARK: - Item 1 row types (feature #4 — local source of truth, offline-first)
//
// Single source of truth: these Sendable structs ARE the GRDB records.
// Column names follow the task-spec schema (snake_case) via CodingKeys.

public enum MessageRole: String, Sendable, Codable, CaseIterable {
    case user, assistant, system, tool
}

/// Message lifecycle: outbound starts `sending`; assistant rows flip to
/// `streaming` while deltas land, then `sent`/`failed`.
public enum MessageStatus: String, Sendable, Codable, CaseIterable {
    case sending, sent, failed, streaming
}

public enum RunCardStatus: String, Sendable, Codable, CaseIterable {
    case queued, running, done, failed, cancelled
}

public struct StoredConversation: Sendable, Codable, Equatable, Identifiable,
    FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "conversations"

    public var id: UUID
    public var projectID: UUID?
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var pinned: Bool
    public var archived: Bool
    public var lastMessagePreview: String?

    /// Twin-equality contract (pinned by BuildSmokeTests): `createdAt`
    /// defaults to `updatedAt` so `StoredConversation(id:title:updatedAt:)`
    /// compares equal to the originally constructed value.

    public init(
        id: UUID = UUID(),
        projectID: UUID? = nil,
        title: String,
        createdAt: Date? = nil,
        updatedAt: Date = Date(),
        pinned: Bool = false,
        archived: Bool = false,
        lastMessagePreview: String? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.createdAt = createdAt ?? updatedAt
        self.updatedAt = updatedAt
        self.pinned = pinned
        self.archived = archived
        self.lastMessagePreview = lastMessagePreview
    }

    // GRDB column mapping (task-spec snake_case schema).
    enum CodingKeys: String, CodingKey {
        case id, projectID = "project_id", title
        case createdAt = "created_at", updatedAt = "updated_at"
        case pinned, archived
        case lastMessagePreview = "last_message_preview"
    }
}

public struct StoredMessage: Sendable, Codable, Equatable, Identifiable,
    FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "messages"

    public var id: UUID
    public var conversationID: UUID
    public var role: MessageRole
    public var content: String
    public var status: MessageStatus
    /// Attachment descriptors, persisted inline as JSON.
    public var attachments: [StoredAttachment]
    /// Branch identity for edit→branch (feature #6); nil = trunk.
    public var branchID: String?
    /// Ordinal within the branch for the "‹ 2/3 ›" switcher.
    public var branchIndex: Int
    /// Server-assigned identity once the message is ACKed by the backend
    /// (plan §5.2: local UUID + server ID). nil = not yet synced.
    public var serverID: String?
    /// Outbox contract: true until the server ACKs the send.
    public var pendingSync: Bool
    /// Stream resume pointer (Item 2): highest SSE event id applied to this
    /// message; 0 = none. Feeds the `Last-Event-ID` header on reconnect and
    /// the cold-launch dedupe watermark.
    public var lastEventID: Int64
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        role: MessageRole,
        content: String,
        status: MessageStatus = .sending,
        attachments: [StoredAttachment] = [],
        branchID: String? = nil,
        branchIndex: Int = 0,
        serverID: String? = nil,
        pendingSync: Bool = true,
        lastEventID: Int64 = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.role = role
        self.content = content
        self.status = status
        self.attachments = attachments
        self.branchID = branchID
        self.branchIndex = branchIndex
        self.serverID = serverID
        self.pendingSync = pendingSync
        self.lastEventID = lastEventID
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case conversationID = "conversation_id"
        case role, content, status, attachments
        case branchID = "branch_id"
        case branchIndex = "branch_index"
        case serverID = "server_id"
        case pendingSync = "pending_sync"
        case lastEventID = "last_event_id"
        case createdAt = "created_at"
    }
}

/// Attachment descriptor stored inline as JSON on the message row.
public struct StoredAttachment: Sendable, Codable, Equatable {
    public var id: UUID
    public var kind: String // image | file | audio | paste
    public var name: String
    public var localPath: String?

    public init(id: UUID = UUID(), kind: String, name: String, localPath: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.localPath = localPath
    }
}

public struct StoredBranch: Sendable, Codable, Equatable, Identifiable,
    FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "branches"

    /// Auto-increment row id; nil until inserted.
    public var id: Int64?
    public var conversationID: UUID
    public var parentMessageID: UUID?
    public var branchIndex: Int
    public var active: Bool

    public init(
        id: Int64? = nil,
        conversationID: UUID,
        parentMessageID: UUID? = nil,
        branchIndex: Int = 0,
        active: Bool = true
    ) {
        self.id = id
        self.conversationID = conversationID
        self.parentMessageID = parentMessageID
        self.branchIndex = branchIndex
        self.active = active
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case conversationID = "conversation_id"
        case parentMessageID = "parent_message_id"
        case branchIndex = "branch_index"
        case active
    }
}

public struct OutboxEntry: Sendable, Codable, Equatable, Identifiable,
    FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "outbox"

    public var id: UUID
    /// Free-form JSON payload (kind + ids + body) so Items 2/3 add send
    /// kinds without a schema bump.
    public var payload: OutboxPayload
    public var attempts: Int
    /// When this entry may next be attempted (exponential backoff).
    public var nextRetryAt: Date
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        payload: OutboxPayload,
        attempts: Int = 0,
        nextRetryAt: Date = .init(timeIntervalSince1970: 0),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.payload = payload
        self.attempts = attempts
        self.nextRetryAt = nextRetryAt
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, payload, attempts
        case nextRetryAt = "next_retry_at"
        case createdAt = "created_at"
    }
}

/// What the outbox carries; Codable → the row's payload JSON.
public struct OutboxPayload: Sendable, Codable, Equatable {
    /// Kind tag for a POST-message replay (Item 2).
    public static let sendKind = "send-message"

    public var kind: String // e.g. "send-message"
    public var conversationID: UUID?
    public var messageID: UUID?
    public var body: String

    public init(kind: String, conversationID: UUID? = nil, messageID: UUID? = nil, body: String = "") {
        self.kind = kind
        self.conversationID = conversationID
        self.messageID = messageID
        self.body = body
    }
}

public struct RunCard: Sendable, Codable, Equatable, Identifiable,
    FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "run_cards"

    public var id: UUID
    public var conversationID: UUID
    public var runID: String
    public var status: RunCardStatus
    /// Steps persisted inline as JSON.
    public var steps: [RunStep]

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        runID: String,
        status: RunCardStatus,
        steps: [RunStep] = []
    ) {
        self.id = id
        self.conversationID = conversationID
        self.runID = runID
        self.status = status
        self.steps = steps
    }

    enum CodingKeys: String, CodingKey {
        case id
        case conversationID = "conversation_id"
        case runID = "run_id"
        case status, steps
    }
}

public struct RunStep: Sendable, Codable, Equatable {
    public var title: String
    public var detail: String?
    public var done: Bool

    public init(title: String, detail: String? = nil, done: Bool = false) {
        self.title = title
        self.detail = detail
        self.done = done
    }
}

/// One row of the App-Group snapshot table (feature #40 prep). The widgets
/// extension later reads ONLY this table; the app is the only writer.
public struct WidgetSnapshotEntry: Sendable, Codable, Equatable,
    FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "widget_snapshot"

    public var key: String
    public var valueJSON: String
    public var updatedAt: Date

    public init(key: String, valueJSON: String, updatedAt: Date = Date()) {
        self.key = key
        self.valueJSON = valueJSON
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case key
        case valueJSON = "value_json"
        case updatedAt = "updated_at"
    }
}

// MARK: - v2 row types (§5.2 completeness — projects / runs / transcripts)

public enum RunStatus: String, Sendable, Codable, CaseIterable {
    case queued, running, done, failed, cancelled
}

public enum RunStepState: String, Sendable, Codable, CaseIterable {
    case pending, running, done, failed
}

public struct StoredProject: Sendable, Codable, Equatable, Identifiable,
    FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "projects"

    public var id: UUID
    public var name: String
    public var instructions: String
    /// Sidebar Pinned section mixes pinned chats + pinned projects (UI Law §1).
    public var pinned: Bool
    /// Item 10: archived projects leave the sidebar tree + Project Home
    /// surfaces but keep their row (mirrors the conversation archive rule).
    public var archived: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        instructions: String = "",
        createdAt: Date? = nil,
        updatedAt: Date = Date(),
        pinned: Bool = false,
        archived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.pinned = pinned
        self.archived = archived
        self.createdAt = createdAt ?? updatedAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, instructions, pinned, archived
        case createdAt = "created_at", updatedAt = "updated_at"
    }
}

public struct StoredRun: Sendable, Codable, Equatable, Identifiable,
    FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "runs"

    public var id: UUID
    public var conversationID: UUID?
    public var projectID: UUID?
    public var status: RunStatus
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        conversationID: UUID? = nil,
        projectID: UUID? = nil,
        status: RunStatus = .queued,
        createdAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.projectID = projectID
        self.status = status
        self.createdAt = createdAt ?? updatedAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case conversationID = "conversation_id"
        case projectID = "project_id"
        case status
        case createdAt = "created_at", updatedAt = "updated_at"
    }
}

public struct StoredRunStep: Sendable, Codable, Equatable, Identifiable,
    FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "run_steps"

    /// Auto-increment row id; nil until inserted.
    public var id: Int64?
    public var runID: UUID
    public var title: String
    public var state: RunStepState
    /// Ordinal within the run's step list.
    public var stepOrder: Int

    public init(
        id: Int64? = nil,
        runID: UUID,
        title: String,
        state: RunStepState = .pending,
        stepOrder: Int = 0
    ) {
        self.id = id
        self.runID = runID
        self.title = title
        self.state = state
        self.stepOrder = stepOrder
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    enum CodingKeys: String, CodingKey {
        case id
        case runID = "run_id"
        case title, state
        case stepOrder = "step_order"
    }
}

public struct StoredRecording: Sendable, Codable, Equatable, Identifiable,
    FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "recordings"

    public var id: UUID
    /// File reference (App Group container path) for the audio asset.
    public var filePath: String
    /// Duration in seconds.
    public var duration: Double
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        filePath: String,
        duration: Double = 0,
        createdAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.filePath = filePath
        self.duration = duration
        self.createdAt = createdAt ?? updatedAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case filePath = "file_path"
        case duration
        case createdAt = "created_at", updatedAt = "updated_at"
    }
}

public struct StoredTranscriptSegment: Sendable, Codable, Equatable, Identifiable,
    FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "transcript_segments"

    public var id: UUID
    public var recordingID: UUID
    public var speaker: String
    public var text: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        recordingID: UUID,
        speaker: String = "",
        text: String,
        createdAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.recordingID = recordingID
        self.speaker = speaker
        self.text = text
        self.createdAt = createdAt ?? updatedAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case recordingID = "recording_id"
        case speaker, text
        case createdAt = "created_at", updatedAt = "updated_at"
    }
}

/// One user-attached source of a project (Item 10, package §05 project
/// model: `ProjectSource{id,projectId,kind,uriOrFileId}`). Rows are deleted
/// with their project (FK cascade); `displayOrder` pins list position.
public struct StoredProjectSource: Sendable, Codable, Equatable, Identifiable,
    FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "project_sources"

    public var id: UUID
    public var projectID: UUID
    /// `file` | `link` (open set; unknown kinds render as their raw string).
    public var kind: String
    /// Local file path or remote URI (package `uriOrFileId`).
    public var reference: String
    public var name: String
    public var displayOrder: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        kind: String,
        reference: String,
        name: String,
        displayOrder: Int = 0,
        createdAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.kind = kind
        self.reference = reference
        self.name = name
        self.displayOrder = displayOrder
        self.createdAt = createdAt ?? updatedAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case projectID = "project_id"
        case kind, reference, name
        case displayOrder = "display_order"
        case createdAt = "created_at", updatedAt = "updated_at"
    }
}

// MARK: - Uniform date storage (REAL unix seconds, full precision)
//
// GRDB's default `deferredToDate` strategy stores Date as ms-truncated TEXT,
// which loses sub-millisecond precision and breaks the pinned
// `fetched == conv` round-trip contracts. Every persisted row opts into REAL
// unix seconds via GRDB 7's record-level strategy hooks (verified against
// GRDB 7.11: EncodableRecord.databaseDateEncodingStrategy(for:),
// FetchableRecord.databaseDateDecodingStrategy(for:)). Declared per type so
// each is unambiguously the protocol witness.

extension StoredConversation {
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }
}

extension StoredMessage {
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }
}

extension StoredBranch {
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }
}

extension OutboxEntry {
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }
}

extension RunCard {
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }
}

extension WidgetSnapshotEntry {
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }
}

extension StoredProject {
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }
}

extension StoredRun {
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }
}

extension StoredRunStep {
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }
}

extension StoredRecording {
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }
}

extension StoredTranscriptSegment {
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }
}

// MARK: - Migration contract (pinned by BuildSmokeTests — extend, don't break)

/// One entry in the shipped migration chain. The contract: `Schema.migrations`
/// must stay strictly ascending in `order` with unique identifiers, and
/// `Schema.isWellOrdered` must keep rejecting bad chains.
public struct Migration: Sendable, Equatable {
    public let identifier: String
    public let order: Int

    public init(identifier: String, order: Int) {
        self.identifier = identifier
        self.order = order
    }
}

public enum Schema {
    /// Migration identifiers. Sequential + well-ordered; future schema
    /// changes APPEND a new entry — never rewrite shipped ones.
    public enum Migrations {
        /// v1 core tables (conversations, messages, branches, outbox, run_cards).
        public static let v1 = Migration(identifier: "v1.core-tables", order: 1)
        /// FTS5 full-text index over message content (synchronized by triggers).
        public static let v1FTS = Migration(identifier: "v1.fts5-index", order: 2)
        /// App-Group widget snapshot table (feature #40 prep, schema only).
        public static let v1WidgetSnapshot = Migration(identifier: "v1.widget-snapshot", order: 3)
        /// v2 §5.2 completeness: projects, runs, run_steps, recordings,
        /// transcript_segments (additive — v1 history is never rewritten).
        public static let v2ProjectsRuns = Migration(identifier: "v2.projects-runs-recordings", order: 4)
        /// v2 message sync columns: persisted server_id (unique) + pending_sync.
        public static let v2MessageSyncColumns = Migration(identifier: "v2.messages-sync-columns", order: 5)
        /// v2FTS: FTS5 index over transcript segment text (unified search).
        public static let v2FTSTranscripts = Migration(identifier: "v2.fts5-transcripts", order: 6)
        /// Item 2 (#1): per-message stream resume pointer (`last_event_id`).
        public static let v2LastEventID = Migration(identifier: "v2.last-event-id", order: 7)
        /// Item 3 (#2): project pin flag for the sidebar Pinned section.
        public static let v2ProjectPinned = Migration(identifier: "v2.projects-pinned", order: 8)
        /// Item 10 (#10): project sources (files/links attached to a project).
        public static let v2ProjectSources = Migration(identifier: "v2.project-sources", order: 9)
        /// Item 10: project archive flag (archived projects keep their rows).
        public static let v2ProjectsArchived = Migration(identifier: "v2.projects-archived", order: 10)
    }

    /// Ordered migration list — strictly ascending `order`, unique ids.
    public static let migrations: [Migration] = [
        Migrations.v1,
        Migrations.v1FTS,
        Migrations.v1WidgetSnapshot,
        Migrations.v2ProjectsRuns,
        Migrations.v2MessageSyncColumns,
        Migrations.v2FTSTranscripts,
        Migrations.v2LastEventID,
        Migrations.v2ProjectPinned,
        Migrations.v2ProjectSources,
        Migrations.v2ProjectsArchived,
    ]

    /// Pure validation of the migration chain — unit-testable anywhere.
    public static func isWellOrdered(_ migrations: [Migration]) -> Bool {
        guard migrations.map(\.order) == migrations.map(\.order).sorted() else { return false }
        let ids = migrations.map(\.identifier)
        return ids.count == Set(ids).count
    }
}
