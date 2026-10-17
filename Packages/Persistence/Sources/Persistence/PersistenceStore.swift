import Foundation

/// Migration scaffold (plan §5.2). Item 1 (feature #4) replaces the in-memory
/// table set with real GRDB tables + FTS5; the migration identity/linting
/// contract starts here so Item 1 grows it without breaking callers.
public struct Migration: Sendable, Equatable {
    public let identifier: String
    public let order: Int

    public init(identifier: String, order: Int) {
        self.identifier = identifier
        self.order = order
    }
}

public enum Schema {
    /// Ordered migration list. Item 0 ships an empty scaffold — `migrations`
    /// must stay strictly ascending in `order` (linted in tests).
    public static let migrations: [Migration] = []

    /// Pure validation of the migration chain — unit-testable on Linux.
    public static func isWellOrdered(_ migrations: [Migration]) -> Bool {
        guard migrations.map(\.order) == migrations.map(\.order).sorted() else { return false }
        let ids = migrations.map(\.identifier)
        return ids.count == Set(ids).count
    }
}

/// GRDB store stub. The real GRDBDatabaseActor lands in Item 1 with the
/// `conversations`/`messages`/`runs`/... tables, outbox queue, and the
/// App-Group snapshot table. In-memory echo below keeps the target compilable
/// and the API shape reviewable today.
public actor PersistenceStore {
    private var conversations: [UUID: StoredConversation] = [:]

    public init() {}

    public func upsert(_ conversation: StoredConversation) {
        conversations[conversation.id] = conversation
    }

    public func get(id: UUID) -> StoredConversation? {
        conversations[id]
    }

    public func count() -> Int {
        conversations.count
    }
}

public struct StoredConversation: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String, updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
    }
}
