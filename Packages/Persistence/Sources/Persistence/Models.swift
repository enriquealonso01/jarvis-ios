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
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case conversationID = "conversation_id"
        case role, content, status, attachments
        case branchID = "branch_id"
        case branchIndex = "branch_index"
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
    }

    /// Ordered migration list — strictly ascending `order`, unique ids.
    public static let migrations: [Migration] = [
        Migrations.v1,
        Migrations.v1FTS,
        Migrations.v1WidgetSnapshot,
    ]

    /// Pure validation of the migration chain — unit-testable anywhere.
    public static func isWellOrdered(_ migrations: [Migration]) -> Bool {
        guard migrations.map(\.order) == migrations.map(\.order).sorted() else { return false }
        let ids = migrations.map(\.identifier)
        return ids.count == Set(ids).count
    }
}
