import Foundation

// MARK: - Stored rows (Sendable struct snapshots crossing the actor boundary)
//
// Item 1 (feature #4) row types. GRDB persistence conformance lives in
// PersistenceStore.swift (FetchableRecord/MutablePersistableRecord); these
// declarations are the single source of truth for the shapes. Item 0's
// scaffold-shape API (id/title/updatedAt) is preserved as a superset.

public enum MessageRole: String, Sendable, Codable, CaseIterable {
    case user, assistant, system, tool
}

/// Message lifecycle: every outbound message starts `sending`; the stream
/// engine (Item 2) flips assistant rows to `streaming` then `sent`/`failed`.
public enum MessageStatus: String, Sendable, Codable, CaseIterable {
    case sending, sent, failed, streaming
}

public enum RunCardStatus: String, Sendable, Codable, CaseIterable {
    case queued, running, done, failed, cancelled
}

public struct StoredConversation: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var projectID: UUID?
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var pinned: Bool
    public var archived: Bool
    public var lastMessagePreview: String?

    public init(
        id: UUID = UUID(),
        projectID: UUID? = nil,
        title: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        pinned: Bool = false,
        archived: Bool = false,
        lastMessagePreview: String? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.pinned = pinned
        self.archived = archived
        self.lastMessagePreview = lastMessagePreview
    }
}

public struct StoredMessage: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var conversationID: UUID
    public var serverID: String?
    public var pendingSync: Bool
    public var role: MessageRole
    public var content: String
    public var status: MessageStatus
    public var attachments: [StoredAttachment]
    public var branchID: Int64?
    public var branchIndex: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        serverID: String? = nil,
        pendingSync: Bool = false,
        role: MessageRole,
        content: String,
        status: MessageStatus = .sending,
        attachments: [StoredAttachment] = [],
        branchID: Int64? = nil,
        branchIndex: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.serverID = serverID
        self.pendingSync = pendingSync
        self.role = role
        self.content = content
        self.status = status
        self.attachments = attachments
        self.branchID = branchID
        self.branchIndex = branchIndex
        self.createdAt = createdAt
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

public struct StoredBranch: Sendable, Codable, Equatable, Identifiable {
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
}

public struct OutboxEntry: Sendable, Codable, Equatable, Identifiable {
    public var id: Int64?
    public var payload: OutboxPayload
    public var attempts: Int
    public var nextRetryAt: Date
    public var createdAt: Date

    public init(
        id: Int64? = nil,
        payload: OutboxPayload,
        attempts: Int = 0,
        nextRetryAt: Date = Date(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.payload = payload
        self.attempts = attempts
        self.nextRetryAt = nextRetryAt
        self.createdAt = createdAt
    }
}

/// What the outbox carries. Extensible via new `kind` values so Items 2/3 can
/// add send kinds without a schema bump.
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

public struct RunCard: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var conversationID: UUID
    public var runID: String
    public var status: RunCardStatus
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

/// One key/value row of the App-Group snapshot table (feature #40). The
/// widgets extension decodes these; the app is the only writer.
public struct WidgetSnapshotEntry: Sendable, Codable, Equatable {
    public var key: String
    public var valueJSON: String
    public var updatedAt: Date

    public init(key: String, valueJSON: String, updatedAt: Date = Date()) {
        self.key = key
        self.valueJSON = valueJSON
        self.updatedAt = updatedAt
    }
}
