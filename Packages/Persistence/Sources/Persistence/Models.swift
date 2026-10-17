import Foundation

// MARK: - Stored rows (Sendable snapshots crossing the actor boundary)

/// Conversation row (plan §5.2 `conversations`). Sendable snapshot.
public struct StoredConversation: Sendable, Equatable, Identifiable, Codable {
    /// Local primary key (UUID, app-generated).
    public var id: UUID
    /// Server-side conversation id, once the server has assigned one.
    public var serverID: String?
    public var projectID: UUID?
    public var title: String
    /// True while any row (conversation or its messages) has unsent local writes.
    public var pendingSync: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        serverID: String? = nil,
        projectID: UUID? = nil,
        title: String,
        pendingSync: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.serverID = serverID
        self.projectID = projectID
        self.title = title
        self.pendingSync = pendingSync
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Message row (plan §5.2 `messages`): local UUID + server ID + pendingSync +
/// branchId + branchIndex. Streaming deltas upsert this row in place.
public struct StoredMessage: Sendable, Equatable, Identifiable, Codable {
    public enum Role: String, Sendable, Codable, CaseIterable {
        case user, assistant, system, tool
    }

    /// Local primary key (UUID, app-generated).
    public var id: UUID
    /// Server-side message id, once assigned.
    public var serverID: String?
    public var conversationID: UUID
    public var role: Role
    /// Body text. Streaming deltas append/replace this via upsert.
    public var body: String
    /// Unsent local write — outbox drains these first.
    public var pendingSync: Bool
    /// Branch identity for edit-→-branch (feature #6); nil = trunk.
    public var branchID: String?
    /// Ordinal within the branch for the "< 2/3 >" switcher.
    public var branchIndex: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        serverID: String? = nil,
        conversationID: UUID,
        role: Role,
        body: String,
        pendingSync: Bool = true,
        branchID: String? = nil,
        branchIndex: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.serverID = serverID
        self.conversationID = conversationID
        self.role = role
        self.body = body
        self.pendingSync = pendingSync
        self.branchID = branchID
        self.branchIndex = branchIndex
        self.createdAt = createdAt
    }
}

/// Project row (plan §5.2 `projects`).
public struct StoredProject: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var serverID: String?
    public var name: String
    public var instructions: String?
    public var pendingSync: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        serverID: String? = nil,
        name: String,
        instructions: String? = nil,
        pendingSync: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.serverID = serverID
        self.name = name
        self.instructions = instructions
        self.pendingSync = pendingSync
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Agent run row (plan §5.2 `runs`).
public struct StoredRun: Sendable, Equatable, Identifiable, Codable {
    public enum Status: String, Sendable, Codable {
        case queued, running, needsApproval, done, failed, cancelled
    }

    public var id: UUID
    public var serverID: String?
    public var conversationID: UUID?
    public var projectID: UUID?
    public var title: String
    public var status: Status
    public var pendingSync: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        serverID: String? = nil,
        conversationID: UUID? = nil,
        projectID: UUID? = nil,
        title: String,
        status: Status = .queued,
        pendingSync: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.serverID = serverID
        self.conversationID = conversationID
        self.projectID = projectID
        self.title = title
        self.status = status
        self.pendingSync = pendingSync
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Agent run step row (plan §5.2 `run_steps`).
public struct StoredRunStep: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var runID: UUID
    public var index: Int
    public var title: String
    public var detail: String?
    public var done: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        runID: UUID,
        index: Int,
        title: String,
        detail: String? = nil,
        done: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.runID = runID
        self.index = index
        self.title = title
        self.detail = detail
        self.done = done
        self.createdAt = createdAt
    }
}

/// Recording row (plan §5.2 `recordings`).
public struct StoredRecording: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var serverID: String?
    public var conversationID: UUID?
    public var projectID: UUID?
    public var title: String
    /// Local file URL (path string) of the audio asset.
    public var filePath: String
    public var durationSeconds: Double
    public var pendingSync: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        serverID: String? = nil,
        conversationID: UUID? = nil,
        projectID: UUID? = nil,
        title: String,
        filePath: String,
        durationSeconds: Double = 0,
        pendingSync: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.serverID = serverID
        self.conversationID = conversationID
        self.projectID = projectID
        self.title = title
        self.filePath = filePath
        self.durationSeconds = durationSeconds
        self.pendingSync = pendingSync
        self.createdAt = createdAt
    }
}

/// Diarized transcript segment row (plan §5.2 `transcript_segments`), FTS-indexed.
public struct StoredTranscriptSegment: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var recordingID: UUID
    /// Speaker label from diarization.
    public var speaker: String?
    public var text: String
    public var startSeconds: Double
    public var endSeconds: Double
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        recordingID: UUID,
        speaker: String? = nil,
        text: String,
        startSeconds: Double = 0,
        endSeconds: Double = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.recordingID = recordingID
        self.speaker = speaker
        self.text = text
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.createdAt = createdAt
    }
}

/// Denormalized widget snapshot (plan §5.2 App-Group table). The widget reads
/// ONLY this table: agent status + last reply, nothing else.
public struct WidgetSnapshot: Sendable, Equatable, Codable {
    public var agentStatus: String
    public var activeRuns: Int
    public var lastReply: String?
    public var lastReplyConversationID: UUID?
    public var updatedAt: Date

    public init(
        agentStatus: String,
        activeRuns: Int = 0,
        lastReply: String? = nil,
        lastReplyConversationID: UUID? = nil,
        updatedAt: Date = Date()
    ) {
        self.agentStatus = agentStatus
        self.activeRuns = activeRuns
        self.lastReply = lastReply
        self.lastReplyConversationID = lastReplyConversationID
        self.updatedAt = updatedAt
    }
}

/// One queued outbound send. `payload` is the transport-agnostic body (JSON
/// dictionary); the outbox drain hands it to the injected send closure.
public struct OutboxEntry: Sendable, Equatable, Identifiable, Codable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case sendMessage, conversationCreate, runAction, recordingUpload
    }

    public var id: UUID
    public var kind: Kind
    /// JSON object payload for the send closure.
    public var payload: [String: String]
    public var attempt: Int
    /// Monotonic-seconds epoch when this entry may next be attempted.
    public var nextAttemptAt: Double
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        payload: [String: String],
        attempt: Int = 0,
        nextAttemptAt: Double = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.payload = payload
        self.attempt = attempt
        self.nextAttemptAt = nextAttemptAt
        self.createdAt = createdAt
    }
}

// MARK: - Migration scaffold (kept from Item 0; contract unchanged)

/// Migration descriptor (Item 0 contract — BuildSmokeTests pins the validator).
public struct Migration: Sendable, Equatable {
    public let identifier: String
    public let order: Int

    public init(identifier: String, order: Int) {
        self.identifier = identifier
        self.order = order
    }
}

public enum Schema {
    /// Ordered migration list — real GRDB migrations land via
    /// `PersistenceStore.migrator()`; this remains the pure, Linux-runnable
    /// chain description for lint tests.
    public static let migrations: [Migration] = [
        Migration(identifier: "v2.core-tables", order: 1),
        Migration(identifier: "v2.fts5-index", order: 2),
        Migration(identifier: "v2.widget-snapshot", order: 3),
        Migration(identifier: "v2.outbox", order: 4),
    ]

    /// Pure validation of the migration chain — unit-testable on Linux.
    public static func isWellOrdered(_ migrations: [Migration]) -> Bool {
        guard migrations.map(\.order) == migrations.map(\.order).sorted() else { return false }
        let ids = migrations.map(\.identifier)
        return ids.count == Set(ids).count
    }
}
