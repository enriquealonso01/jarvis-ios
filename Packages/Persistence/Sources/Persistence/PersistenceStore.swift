import Foundation
import GRDB

// MARK: - Migration contract (pinned by BuildSmokeTests — extend, don't break)

/// One entry in the shipped migration chain. The ordering/linting contract
/// from Item 0 is preserved: `Schema.migrations` must stay strictly ascending
/// in `order` with unique identifiers, and `Schema.isWellOrdered` must keep
/// rejecting bad chains.
public struct Migration: Sendable, Equatable {
    public let identifier: String
    public let order: Int

    public init(identifier: String, order: Int) {
        self.identifier = identifier
        self.order = order
    }
}

public enum Schema {
    /// GRDB migration identifiers, v1 (feature #4). Sequential and
    /// well-ordered; each future schema change appends a new entry.
    public enum Migrations {
        public static let v1 = Migration(identifier: "v1.core-tables", order: 1)
    }

    /// Ordered migration list — strictly ascending `order`, unique ids.
    public static let migrations: [Migration] = [
        Migrations.v1,
    ]

    /// Pure validation of the migration chain — unit-testable on Linux.
    public static func isWellOrdered(_ migrations: [Migration]) -> Bool {
        guard migrations.map(\.order) == migrations.map(\.order).sorted() else { return false }
        let ids = migrations.map(\.identifier)
        return ids.count == Set(ids).count
    }

    /// Run the shipped chain on a database writer.
    public static func migrate(_ dbQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        for migration in migrations {
            migrator.registerMigration(migration.identifier, order: migration.order) { db in
                try Self.v1(db)
            }
        }
        try migrator.migrate(dbQueue)
    }

    /// Schema v1 — conversations, messages, branches, outbox, run_cards and
    /// the widget-read App-Group snapshot table + FTS5 index over messages.
    static func v1(_ db: Database) throws {
        // Conversations — the sidebar's source of truth.
        try db.create(table: "conversations") { t in
            t.primaryKey("id", .text)
            t.column("projectID", .text).indexed()
            t.column("title", .text).notNull().defaults(to: "")
            t.column("createdAt", .datetime).notNull()
            t.column("updatedAt", .datetime).notNull().indexed()
            t.column("pinned", .boolean).notNull().defaults(to: false)
            t.column("archived", .boolean).notNull().defaults(to: false).indexed()
            t.column("lastMessagePreview", .text)
        }

        // Messages — local UUID primary key, server id kept for delta-sync.
        try db.create(table: "messages") { t in
            t.primaryKey("id", .text)
            t.column("conversationID", .text)
                .notNull()
                .indexed()
                .references("conversations", onDelete: .cascade)
            t.column("serverID", .text).indexed()
            t.column("pendingSync", .boolean).notNull().defaults(to: false)
            t.column("role", .text).notNull() // user | assistant | system | tool
            t.column("content", .text).notNull().defaults(to: "")
            // sending | sent | failed | streaming (MessageStatus)
            t.column("status", .text).notNull().defaults(to: MessageStatus.sending.rawValue)
            t.column("attachmentsJSON", .text)
            t.column("branchID", .text).indexed()
            t.column("branchIndex", .integer).notNull().defaults(to: 0)
            t.column("createdAt", .datetime).notNull().indexed()
        }

        // Branches — ChatGPT-style alternate reply trees (feature #6 prep).
        try db.create(table: "branches") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("conversationID", .text)
                .notNull()
                .indexed()
                .references("conversations", onDelete: .cascade)
            t.column("parentMessageID", .text).indexed()
            t.column("branchIndex", .integer).notNull().defaults(to: 0)
            t.column("active", .boolean).notNull().defaults(to: true).indexed()
        }

        // Outbox — offline-first send queue with retry/backoff.
        try db.create(table: "outbox") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("payloadJSON", .text).notNull()
            t.column("attempts", .integer).notNull().defaults(to: 0)
            t.column("nextRetryAt", .datetime).indexed()
            t.column("createdAt", .datetime).notNull()
        }

        // Run cards — agent run status for the Runs surface.
        try db.create(table: "run_cards") { t in
            t.primaryKey("id", .text)
            t.column("conversationID", .text)
                .notNull()
                .indexed()
                .references("conversations", onDelete: .cascade)
            t.column("runID", .text).notNull().indexed()
            t.column("status", .text).notNull() // queued | running | done | failed | cancelled
            t.column("stepsJSON", .text).notNull().defaults(to: "[]")
        }

        // App-Group snapshot — denormalized, read-only-from-the-widget table
        // the widgets extension reads for "Online · 3 tasks · last reply 2m
        // ago" (feature #40). The widget touches ONLY this table.
        try db.create(table: "widget_snapshot") { t in
            t.primaryKey("key", .text)
            t.column("valueJSON", .text).notNull()
            t.column("updatedAt", .datetime).notNull()
        }

        // FTS5 full-text search over message bodies (unified search, feature
        // #7 prep). External-content table + triggers keep the index in sync
        // with messages automatically.
        try db.execute(sql: """
            CREATE VIRTUAL TABLE messages_fts USING fts5(
                content,
                content='messages',
                content_rowid='rowid',
                tokenize='porter unicode61'
            )
            """)
        try db.execute(sql: """
            CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN
                INSERT INTO messages_fts(rowid, content) VALUES (new.rowid, new.content);
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER messages_ad AFTER DELETE ON messages BEGIN
                INSERT INTO messages_fts(messages_fts, rowid, content)
                VALUES ('delete', old.rowid, old.content);
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER messages_au AFTER UPDATE ON messages BEGIN
                INSERT INTO messages_fts(messages_fts, rowid, content)
                VALUES ('delete', old.rowid, old.content);
                INSERT INTO messages_fts(rowid, content) VALUES (new.rowid, new.content);
            END
            """)
    }
}

// MARK: - PersistenceStore

/// The local source of truth (plan §5.2). All I/O on this actor; callers get
/// Sendable struct snapshots. Offline-first: sends go through the outbox and
/// replay with exponential backoff until acked.
public actor PersistenceStore {
    /// Messages per page for `fetchMessages`.
    public static let messagePageSize = 50

    /// Backoff base for outbox retries: 2^attempts seconds, capped at 60s.
    public static let retryBackoffCap: TimeInterval = 60

    private let dbQueue: DatabaseQueue

    /// In-memory store (tests, previews). Never touches disk.
    public convenience init(inMemory: Bool = false) throws {
        try self.init(dbQueue: DatabaseQueue())
    }

    /// Non-throwing in-memory init for the pinned scaffold contract (tests,
    /// previews). Migration failure on a fresh in-memory DB is a programmer
    /// error — CI catches it via PersistenceTests, so trap loudly.
    public convenience init() {
        do {
            try self.init(inMemory: true)
        } catch {
            fatalError("PersistenceStore in-memory init failed: \(error)")
        }
    }

    /// On-disk store. `path` points inside the App Group container when the
    /// entitlement is present (feature #40), else the app's own support dir.
    public convenience init(path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try self.init(dbQueue: DatabaseQueue(path: path))
    }

    init(dbQueue: DatabaseQueue, runMigrations: Bool = true) throws {
        self.dbQueue = dbQueue
        if runMigrations {
            try Schema.migrate(dbQueue)
        }
    }

    // MARK: Conversations

    /// The shipped scaffold API: fresh store starts empty, accepts an upsert,
    /// returns exactly what was written, and upsert never appends duplicates.
    /// Now backed by real GRDB (Item 1) — same contract, real tables.
    public func count() -> Int {
        (try? countConversations()) ?? 0
    }

    /// Non-throwing upsert for the pinned scaffold contract.
    public func upsert(_ conversation: StoredConversation) {
        try? upsertConv(conversation)
    }

    /// Non-throwing fetch for the pinned scaffold contract.
    public func get(id: UUID) -> StoredConversation? {
        try? getConv(id: id)
    }

    /// Throwing variants (internal, real implementations).
    func upsertConv(_ conversation: StoredConversation) throws {
        try dbQueue.write { db in
            try conversation.save(db)
        }
    }

    func getConv(id: UUID) throws -> StoredConversation? {
        try dbQueue.read { db in
            try StoredConversation.fetchOne(db, key: id.uuidString)
        }
    }

    /// Sidebar list: pinned first, then most-recently-updated.
    /// `archived: false` by default; pass true for the archive view.
    public func fetchConversations(
        archived: Bool = false,
        limit: Int = 100,
        offset: Int = 0
    ) throws -> [StoredConversation] {
        try dbQueue.read { db in
            try StoredConversation
                .filter(Column("archived") == archived)
                .order(!Column("pinned"), Column("updatedAt").desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    public func countConversations() throws -> Int {
        try dbQueue.read { db in
            try StoredConversation.fetchCount(db)
        }
    }

    public func delete(id: UUID) throws {
        try dbQueue.write { db in
            _ = try StoredConversation.deleteOne(db, key: id.uuidString)
        }
    }

    // MARK: Messages

    /// Insert-or-replace one message; keeps the conversation's preview +
    /// `updatedAt` fresh (the list stays sorted without a second query).
    public func upsert(_ message: StoredMessage) throws {
        try dbQueue.write { db in
            try message.save(db)
            try db.execute(
                sql: "UPDATE conversations SET lastMessagePreview = ?, updatedAt = ? WHERE id = ?",
                arguments: [String(message.content.prefix(120)), message.createdAt, message.conversationID.uuidString]
            )
        }
    }

    public func get(id: UUID) throws -> StoredMessage? {
        try dbQueue.read { db in
            try StoredMessage.fetchOne(db, key: id.uuidString)
        }
    }

    /// Paginated transcript. `page` is 0-based, newest page last: the UI asks
    /// for the final pages as the user scrolls up through history.
    public func fetchMessages(
        conversationID: UUID,
        page: Int,
        pageSize: Int = PersistenceStore.messagePageSize
    ) throws -> [StoredMessage] {
        try dbQueue.read { db in
            try StoredMessage
                .filter(Column("conversationID") == conversationID.uuidString)
                .order(Column("createdAt").asc, Column("rowid").asc)
                .limit(pageSize, offset: page * pageSize)
                .fetchAll(db)
        }
    }

    public func messageCount(conversationID: UUID) throws -> Int {
        try dbQueue.read { db in
            try StoredMessage
                .filter(Column("conversationID") == conversationID.uuidString)
                .fetchCount(db)
        }
    }

    /// Streaming engine hook (Item 2): mutate just the status/content of one
    /// message without a full fetch-modify-save round-trip.
    public func updateMessage(
        id: UUID,
        content: String? = nil,
        status: MessageStatus? = nil,
        serverID: String? = nil
    ) throws {
        try dbQueue.write { db in
            var message = try StoredMessage.fetchOne(db, key: id.uuidString)
            guard var message else { return }
            if let content { message.content = content }
            if let status { message.status = status }
            if let serverID { message.serverID = serverID }
            try message.save(db)
        }
    }

    // MARK: Branches

    @discardableResult
    public func insertBranch(_ branch: StoredBranch) throws -> StoredBranch {
        try dbQueue.write { db in
            var branch = branch
            try branch.insert(db)
            return branch
        }
    }

    public func fetchBranches(conversationID: UUID) throws -> [StoredBranch] {
        try dbQueue.read { db in
            try StoredBranch
                .filter(Column("conversationID") == conversationID.uuidString)
                .order(Column("branchIndex").asc)
                .fetchAll(db)
        }
    }

    /// Activate one branch, deactivate its siblings (single-active rule).
    public func setActiveBranch(id: Int64, conversationID: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE branches SET active = 0 WHERE conversationID = ?",
                arguments: [conversationID.uuidString]
            )
            try db.execute(
                sql: "UPDATE branches SET active = 1 WHERE id = ?",
                arguments: [id]
            )
        }
    }

    public func deleteBranch(id: Int64) throws {
        try dbQueue.write { db in
            _ = try StoredBranch.deleteOne(db, key: id)
        }
    }

    // MARK: Outbox (offline-first send queue)

    /// Enqueue a pending send. Assigns an id and returns the stored entry.
    @discardableResult
    public func enqueue(_ payload: OutboxPayload) throws -> OutboxEntry {
        try dbQueue.write { db in
            var entry = OutboxEntry(payload: payload)
            try entry.insert(db)
            return entry
        }
    }

    /// Drain-ready entries: never-tried or backoff-expired, oldest first.
    public func dueOutbox(now: Date = Date(), limit: Int = 20) throws -> [OutboxEntry] {
        try dbQueue.read { db in
            try OutboxEntry
                .filter(Column("nextRetryAt") <= now)
                .order(Column("createdAt").asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Ack a successfully sent entry — removes it from the queue.
    public func ack(id: Int64) throws {
        try dbQueue.write { db in
            _ = try OutboxEntry.deleteOne(db, key: id)
        }
    }

    /// Failure path: bump attempts, schedule the next retry with exponential
    /// backoff (2^attempts seconds, capped at 60).
    public func retry(id: Int64, now: Date = Date()) throws -> OutboxEntry? {
        let cap = PersistenceStore.retryBackoffCap
        return try dbQueue.write { db in
            guard var entry = try OutboxEntry.fetchOne(db, key: id) else { return nil }
            entry.attempts += 1
            let backoff = min(pow(2.0, Double(entry.attempts)), cap)
            entry.nextRetryAt = now.addingTimeInterval(backoff)
            try entry.update(db)
            return entry
        }
    }

    public func outboxCount() throws -> Int {
        try dbQueue.read { db in
            try OutboxEntry.fetchCount(db)
        }
    }

    // MARK: Run cards

    public func upsert(_ runCard: RunCard) throws {
        try dbQueue.write { db in
            try runCard.save(db)
        }
    }

    public func fetchRunCards(conversationID: UUID) throws -> [RunCard] {
        try dbQueue.read { db in
            try RunCard
                .filter(Column("conversationID") == conversationID.uuidString)
                .order(Column("runID").desc)
                .fetchAll(db)
        }
    }

    // MARK: Search (FTS5)

    public struct SearchHit: Sendable, Equatable {
        public let message: StoredMessage
        public let snippet: String
    }

    /// Full-text search over message bodies via the messages_fts index.
    public func searchMessages(_ query: String, limit: Int = 25) throws -> [SearchHit] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.id AS m_id, m.conversationID AS m_conversationID, m.serverID AS m_serverID,
                       m.pendingSync AS m_pendingSync, m.role AS m_role, m.content AS m_content,
                       m.status AS m_status, m.attachmentsJSON AS m_attachmentsJSON,
                       m.branchID AS m_branchID, m.branchIndex AS m_branchIndex, m.createdAt AS m_createdAt,
                       snippet(messages_fts, 0, '<b>', '</b>', '…', 12) AS snip
                FROM messages_fts
                JOIN messages m ON m.rowid = messages_fts.rowid
                WHERE messages_fts MATCH ?
                ORDER BY rank
                LIMIT ?
                """, arguments: [query, limit])
            return try rows.map { row in
                let decoder = JSONDecoder()
                let message = StoredMessage(
                    id: UUID(uuidString: try row["m_id"]) ?? UUID(),
                    conversationID: UUID(uuidString: try row["m_conversationID"]) ?? UUID(),
                    serverID: try row["m_serverID"],
                    pendingSync: try row["m_pendingSync"],
                    role: ((try row["m_role"] as String?).flatMap(MessageRole.init(rawValue:))) ?? .user,
                    content: (try row["m_content"] as String?) ?? "",
                    status: ((try row["m_status"] as String?).flatMap(MessageStatus.init(rawValue:))) ?? .sending,
                    attachments: (try row["m_attachmentsJSON"] as String?).flatMap {
                        try? decoder.decode([StoredAttachment].self, from: Data($0.utf8))
                    } ?? [],
                    branchID: try row["m_branchID"],
                    branchIndex: (try row["m_branchIndex"] as Int?) ?? 0,
                    createdAt: (try row["m_createdAt"] as Date?) ?? Date.distantPast
                )
                return SearchHit(message: message, snippet: (try row["snip"] as String?) ?? "")
            }
        }
    }

    // MARK: App-Group snapshot (feature #40 prep — widget reads only this)

    public func writeSnapshot(_ entry: WidgetSnapshotEntry) throws {
        try dbQueue.write { db in
            try entry.save(db)
        }
    }

    public func readSnapshot(key: String) throws -> WidgetSnapshotEntry? {
        try dbQueue.read { db in
            try WidgetSnapshotEntry.fetchOne(db, key: key)
        }
    }
}

// MARK: - GRDB conformance (Codable records)

extension StoredConversation: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "conversations"

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["projectID"] = projectID?.uuidString
        container["title"] = title
        container["createdAt"] = createdAt
        container["updatedAt"] = updatedAt
        container["pinned"] = pinned
        container["archived"] = archived
        container["lastMessagePreview"] = lastMessagePreview
    }

    public init(row: Row) throws {
        id = try row["id"].map { UUID(uuidString: $0) } ?? UUID()
        projectID = (try row["projectID"] as String?).flatMap(UUID.init(uuidString:))
        title = try row["title"]
        createdAt = try row["createdAt"]
        updatedAt = try row["updatedAt"]
        pinned = try row["pinned"]
        archived = try row["archived"]
        lastMessagePreview = try row["lastMessagePreview"]
    }
}

extension StoredMessage: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "messages"

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["conversationID"] = conversationID.uuidString
        container["serverID"] = serverID
        container["pendingSync"] = pendingSync
        container["role"] = role.rawValue
        container["content"] = content
        container["status"] = status.rawValue
        container["attachmentsJSON"] = attachmentsJSON
        container["branchID"] = branchID
        container["branchIndex"] = branchIndex
        container["createdAt"] = createdAt
    }

    public init(row: Row) throws {
        id = try row["id"].map { UUID(uuidString: $0) } ?? UUID()
        conversationID = try row["conversationID"].map { UUID(uuidString: $0) } ?? UUID()
        serverID = try row["serverID"] as String?
        pendingSync = try row["pendingSync"]
        role = (try row["role"] as String).flatMap(MessageRole.init(rawValue:)) ?? .user
        content = try row["content"]
        status = (try row["status"] as String).flatMap(MessageStatus.init(rawValue:)) ?? .sending
        branchID = try row["branchID"]
        branchIndex = try row["branchIndex"]
        createdAt = try row["createdAt"]
        let json = try row["attachmentsJSON"] as String?
        attachments = json.flatMap {
            try? JSONDecoder().decode([StoredAttachment].self, from: Data($0.utf8))
        } ?? []
    }

    var attachmentsJSON: String? {
        guard !attachments.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(attachments) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension StoredBranch: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "branches"

    public func encode(to container: inout PersistenceContainer) {
        if let id { container["id"] = id }
        container["conversationID"] = conversationID.uuidString
        container["parentMessageID"] = parentMessageID?.uuidString
        container["branchIndex"] = branchIndex
        container["active"] = active
    }

    public init(row: Row) throws {
        id = try row["id"]
        conversationID = try row["conversationID"].map { UUID(uuidString: $0) } ?? UUID()
        parentMessageID = (try row["parentMessageID"] as String?).flatMap(UUID.init(uuidString:))
        branchIndex = try row["branchIndex"]
        active = try row["active"]
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension OutboxEntry: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "outbox"

    public func encode(to container: inout PersistenceContainer) {
        if let id { container["id"] = id }
        container["payloadJSON"] = payloadJSON
        container["attempts"] = attempts
        container["nextRetryAt"] = nextRetryAt
        container["createdAt"] = createdAt
    }

    public init(row: Row) throws {
        id = try row["id"]
        createdAt = try row["createdAt"]
        attempts = try row["attempts"]
        nextRetryAt = try row["nextRetryAt"]
        let json = try row["payloadJSON"] as String
        payload = try JSONDecoder().decode(OutboxPayload.self, from: Data(json.utf8))
    }

    var payloadJSON: String {
        let data = (try? JSONEncoder().encode(payload)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension RunCard: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "run_cards"

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString
        container["conversationID"] = conversationID.uuidString
        container["runID"] = runID
        container["status"] = status.rawValue
        container["stepsJSON"] = stepsJSON
    }

    public init(row: Row) throws {
        id = try row["id"].map { UUID(uuidString: $0) } ?? UUID()
        conversationID = try row["conversationID"].map { UUID(uuidString: $0) } ?? UUID()
        runID = try row["runID"]
        status = (try row["status"] as String).flatMap(RunCardStatus.init(rawValue:)) ?? .queued
        let json = try row["stepsJSON"] as String
        steps = (try? JSONDecoder().decode([RunStep].self, from: Data(json.utf8))) ?? []
    }

    var stepsJSON: String {
        let data = (try? JSONEncoder().encode(steps)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}

extension WidgetSnapshotEntry: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "widget_snapshot"

    public func encode(to container: inout PersistenceContainer) {
        container["key"] = key
        container["valueJSON"] = valueJSON
        container["updatedAt"] = updatedAt
    }

    public init(row: Row) throws {
        key = try row["key"]
        valueJSON = try row["valueJSON"]
        updatedAt = try row["updatedAt"]
    }
}
