import Foundation
import GRDB

/// GRDB-backed local source of truth (plan §5.2, feature #4 — offline-first).
///
/// Actor-isolated; all reads/writes run on a single writer `DatabaseQueue`
/// via GRDB's async access API. Sendable `Stored*` snapshots cross the
/// boundary. The smoke contract from Item 0 is preserved: `PersistenceStore()`
/// starts an empty in-memory store and `upsert`/`get`/`count` are
/// non-throwing `async` (storage failures degrade to nil/empty/false —
/// never crash the UI).
public actor PersistenceStore {
    /// UI pagination contract (pinned by BuildSmokeTests): 50 per page.
    public static let messagePageSize = 50

    private let dbQueue: Void? = nil
    let dbWriter: any DatabaseWriter

    /// In-memory database (tests / previews) — the pinned smoke entry point.
    /// Force-unwrap is safe: an in-memory queue cannot fail to open, and the
    /// Item 0 contract requires a non-failable public initializer.
    /// NOTE: GRDB 7 has NO dateEncoding/DecodingStrategy on Configuration —
    /// Date transcoding is fixed (ms-precision TEXT). Whole-second Date
    /// pinning lives in StoredConversation.init (Models.swift).
    public init() {
        let queue = try! DatabaseQueue()
        try! self.init(dbWriter: queue)
    }

    /// File-backed store. Put `path` in the App Group container so app +
    /// widget extension see the same database (feature #40).
    public init(path: String) throws {
        let queue = try DatabaseQueue(path: path)
        try self.init(dbWriter: queue)
    }

    init(dbWriter: any DatabaseWriter) throws {
        self.dbWriter = dbWriter
        try AppSchema.migrator().migrate(dbWriter)
    }

    public var migrator: DatabaseMigrator { AppSchema.migrator() }

    // MARK: - Conversations

    public func upsert(_ conversation: StoredConversation) async {
        _ = try? await dbWriter.write { db in
            var row = conversation
            try row.save(db)
        }
    }

    public func get(id: UUID) async -> StoredConversation? {
        (try? await dbWriter.read { db in
            try StoredConversation
                .filter(Column("id") == id)
                .fetchOne(db)
        }) ?? nil
    }

    public func count() async -> Int {
        (try? await dbWriter.read { db in
            try StoredConversation.fetchCount(db)
        }) ?? 0
    }

    /// Recents, pinned first, newest first.
    public func conversations(limit: Int = 200) async -> [StoredConversation] {
        (try? await dbWriter.read { db in
            try StoredConversation
                .order(Column("pinned").desc, Column("updated_at").desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }

    public func deleteConversation(id: UUID) async -> Bool {
        guard let deleted = try? await dbWriter.write({ db in
            try StoredConversation.filter(Column("id") == id).deleteAll(db)
        }) else { return false }
        return deleted > 0
    }

    // MARK: - Messages (paginated)

    /// One page of a conversation, oldest first, `messagePageSize` per page.
    /// Page 0 = oldest 50; pages advance forward. For chat-style "newest
    /// page, oldest-first within the page", see `recentMessages`.
    public func fetchMessages(conversationID: UUID, page: Int) async throws -> [StoredMessage] {
        try await pagedMessages(conversationID: conversationID, limit: Self.messagePageSize,
                                offset: page * Self.messagePageSize)
    }

    public func messages(conversationID: UUID) async throws -> [StoredMessage] {
        try await pagedMessages(conversationID: conversationID, limit: nil, offset: 0)
    }

    private func pagedMessages(conversationID: UUID, limit: Int?, offset: Int) async throws -> [StoredMessage] {
        try await dbWriter.read { db in
            var request = StoredMessage
                .filter(Column("conversation_id") == conversationID)
                .order(Column("created_at").asc, Column("id").asc)
            if let limit {
                request = request.limit(limit, offset: offset)
            }
            return try request.fetchAll(db)
        }
    }

    /// Newest page of a conversation, returned oldest-first within the page
    /// (what a chat transcript renders). "Load older" = increasing page.
    /// `limit` overrides the default page size (Item 4 QA suites pin
    /// smallest-tail probes with `limit: 1`).
    public func recentMessages(conversationID: UUID, page: Int = 0, limit: Int? = nil) async throws -> [StoredMessage] {
        let pageSize = limit ?? Self.messagePageSize
        let newest = try await dbWriter.read { db in
            try StoredMessage
                .filter(Column("conversation_id") == conversationID)
                .order(Column("created_at").desc, Column("id").desc)
                .limit(pageSize, offset: page * Self.messagePageSize)
                .fetchAll(db)
        }
        return newest.reversed()
    }

    public func getMessage(id: UUID) async -> StoredMessage? {
        (try? await dbWriter.read { db in
            try StoredMessage.filter(Column("id") == id).fetchOne(db)
        }) ?? nil
    }

    public func messageCount(conversationID: UUID) async -> Int {
        (try? await dbWriter.read { db in
            try StoredMessage.filter(Column("conversation_id") == conversationID).fetchCount(db)
        }) ?? 0
    }

    /// Upsert + touch the conversation (recents ordering + preview).
    public func upsert(_ message: StoredMessage) async {
        _ = try? await dbWriter.write { db in
            var row = message
            try row.save(db)
            try db.execute(
                sql: """
                    UPDATE conversations
                    SET updated_at = ?, last_message_preview = ?
                    WHERE id = ?
                    """,
                arguments: [message.createdAt.timeIntervalSince1970, Self.preview(message.content), message.conversationID]
            )
        }
    }

    private nonisolated static func preview(_ content: String) -> String {
        String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(140))
    }

    /// Streaming delta: upsert the message row in place so a cold launch
    /// mid-stream restores the transcript. `replaceBody: false` appends the
    /// delta (token deltas); `true` replaces the content (snapshot commit).
    /// `lastEventID` persists the stream resume pointer when provided.
    @discardableResult
    public func applyStreamDelta(
        messageID: UUID,
        conversationID: UUID,
        role: MessageRole = .assistant,
        delta: String,
        replaceBody: Bool,
        lastEventID: Int64? = nil
    ) async throws -> StoredMessage {
        try await dbWriter.write { db in
            var row: StoredMessage
            if var existing = try StoredMessage
                .filter(Column("id") == messageID)
                .fetchOne(db) {
                // Never downgrade a terminal row: a debounced delta flushed
                // after finalize (stop/error) must not resurrect `streaming`.
                guard existing.status == .streaming || existing.status == .sending else {
                    if let lastEventID, existing.lastEventID < lastEventID {
                        existing.lastEventID = lastEventID
                        try existing.save(db)
                    }
                    return existing
                }
                existing.content = replaceBody ? delta : existing.content + delta
                existing.status = .streaming
                if let lastEventID { existing.lastEventID = lastEventID }
                row = existing
            } else {
                row = StoredMessage(
                    id: messageID, conversationID: conversationID,
                    role: role, content: delta, status: .streaming,
                    lastEventID: lastEventID ?? 0
                )
            }
            try row.save(db)
            try db.execute(
                sql: "UPDATE conversations SET updated_at = ? WHERE id = ?",
                arguments: [Date().timeIntervalSince1970, conversationID]
            )
            return row
        }
    }

    // MARK: - Item 2: stream finalization + cold-launch restore (feature #1)

    /// Final commit of a streamed assistant message: terminal status
    /// (`sent` — includes `stopped`, since stop freezes partial content;
    /// `failed` for errors), conversation preview + ordering timestamp.
    /// The 500ms-debounced deltas only ever write `streaming` rows; this is
    /// the one transition the store treats as authoritative.
    @discardableResult
    public func finalizeStreamedMessage(
        id: UUID,
        conversationID: UUID,
        text: String,
        failed: Bool,
        lastEventID: Int64? = nil
    ) async throws -> StoredMessage {
        try await dbWriter.write { db in
            var row = try StoredMessage.filter(Column("id") == id).fetchOne(db)
                ?? StoredMessage(
                    id: id, conversationID: conversationID,
                    role: .assistant, content: text, status: failed ? .failed : .sent
                )
            row.content = text
            row.status = failed ? .failed : .sent
            if let lastEventID { row.lastEventID = lastEventID }
            try row.save(db)
            // Feature #4: conversation preview + ordering stamp move with the
            // latest message (assistant reply is the newest transcript entry).
            try db.execute(
                sql: """
                    UPDATE conversations
                    SET updated_at = ?, last_message_preview = ?
                    WHERE id = ?
                    """,
                arguments: [Date().timeIntervalSince1970, Self.preview(text), conversationID]
            )
            return row
        }
    }

    /// Cold-launch restore (task spec #3): last persisted snapshot for a
    /// conversation + the resume point (highest `last_event_id`) so the live
    /// tail continues from exactly where the store left off.
    public func streamRestoreState(
        conversationID: UUID
    ) async throws -> (snapshot: StoredMessage?, resumeEventID: Int64) {
        try await dbWriter.read { db in
            let snapshot = try StoredMessage
                .filter(Column("conversation_id") == conversationID)
                .filter(Column("status") == MessageStatus.streaming.rawValue)
                .order(Column("created_at").desc, Column("id").desc)
                .fetchOne(db)
            let resume = try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(last_event_id), 0) FROM messages WHERE conversation_id = ?",
                arguments: [conversationID]
            ) ?? 0
            return (snapshot, resume)
        }
    }

    /// IDs of the conversation's still-mid-stream (`streaming`) messages —
    /// the cold-launch restore candidates, oldest first.
    public func streamingMessageIDs(conversationID: UUID) async -> [UUID] {
        (try? await dbWriter.read { db in
            try StoredMessage
                .filter(Column("conversation_id") == conversationID)
                .filter(Column("status") == MessageStatus.streaming.rawValue)
                .order(Column("created_at").asc)
                .fetchAll(db)
                .map(\.id)
        }) ?? []
    }

    // MARK: - Full-text search (FTS5)

    /// Search message content via the FTS5 index (rank-ordered).
    public func searchMessages(matching query: String, limit: Int = 50) async throws -> [StoredMessage] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return try await dbWriter.read { db in
            let sql = """
                SELECT messages.* FROM messages
                JOIN messages_fts ON messages_fts.rowid = messages.rowid
                WHERE messages_fts MATCH ?
                ORDER BY rank
                LIMIT ?
                """
            return try StoredMessage
                .fetchAll(db, sql: sql, arguments: [FTS5Pattern(rawPattern: query), limit])
        }
    }

    // MARK: - Branches

    @discardableResult
    public func upsert(_ branch: StoredBranch) async throws -> StoredBranch {
        try await dbWriter.write { db in
            var b = branch
            try b.save(db)
            return b
        }
    }

    public func branches(conversationID: UUID) async throws -> [StoredBranch] {
        try await dbWriter.read { db in
            try StoredBranch
                .filter(Column("conversation_id") == conversationID)
                .order(Column("branch_index").asc)
                .fetchAll(db)
        }
    }

    /// Deactivate all other branches of a conversation (switch active branch).
    public func setActiveBranch(id: Int64, conversationID: UUID) async throws {
        _ = try await dbWriter.write { db in
            try db.execute(
                sql: "UPDATE branches SET active = false WHERE conversation_id = ?",
                arguments: [conversationID]
            )
            try db.execute(
                sql: "UPDATE branches SET active = true WHERE id = ?",
                arguments: [id]
            )
        }
    }

    public func deleteBranch(id: Int64) async throws {
        _ = try await dbWriter.write { db in
            try StoredBranch.filter(Column("id") == id).deleteAll(db)
        }
    }

    // MARK: - Outbox (enqueue / ack / retry-with-backoff)

    public func enqueue(_ entry: OutboxEntry) async {
        _ = try? await dbWriter.write { db in
            var row = entry
            try row.insert(db)
        }
    }

    public func outboxEntry(id: UUID) async -> OutboxEntry? {
        (try? await dbWriter.read { db in
            try OutboxEntry.filter(Column("id") == id).fetchOne(db)
        }) ?? nil
    }

    public func outboxCount() async -> Int {
        (try? await dbWriter.read { db in
            try OutboxEntry.fetchCount(db)
        }) ?? 0
    }

    /// Due entries, FIFO by enqueue time. Internal: OutboxActor drains.
    func dueOutboxEntries(now: Double) async throws -> [OutboxEntry] {
        try await dbWriter.read { db in
            try OutboxEntry
                .filter(Column("next_retry_at") <= now)
                .order(Column("created_at").asc)
                .fetchAll(db)
        }
    }

    /// Ack: the entry was delivered — it leaves the queue.
    func removeOutboxEntry(id: UUID) async throws {
        _ = try await dbWriter.write { db in
            try OutboxEntry.filter(Column("id") == id).deleteAll(db)
        }
    }

    /// Retry-with-backoff: attempts++ and push next_retry_at out.
    func recordOutboxFailure(id: UUID, nextAttemptAt: Date) async throws {
        _ = try await dbWriter.write { db in
            try db.execute(
                sql: "UPDATE outbox SET attempts = attempts + 1, next_retry_at = ? WHERE id = ?",
                arguments: [nextAttemptAt.timeIntervalSince1970, id]
            )
        }
    }

    /// Reconnect: clear all backoff timers so everything drains immediately.
    func resetOutboxBackoff(now: Date) async throws {
        _ = try await dbWriter.write { db in
            try db.execute(sql: "UPDATE outbox SET next_retry_at = ?",
                           arguments: [now.timeIntervalSince1970])
        }
    }

    // MARK: - Run cards

    public func upsert(_ card: RunCard) async {
        _ = try? await dbWriter.write { db in
            var row = card
            try row.save(db)
        }
    }

    public func runCard(id: UUID) async -> RunCard? {
        (try? await dbWriter.read { db in
            try RunCard.filter(Column("id") == id).fetchOne(db)
        }) ?? nil
    }

    public func runCards(conversationID: UUID) async -> [RunCard] {
        (try? await dbWriter.read { db in
            try RunCard
                .filter(Column("conversation_id") == conversationID)
                .order(Column("created_at").desc)
                .fetchAll(db)
        }) ?? []
    }

    // MARK: - Widget snapshot (App-Group; feature #40 prep)

    /// App-only writer for the snapshot table the widget will read.
    public func updateWidgetSnapshot(_ entry: WidgetSnapshotEntry) async {
        _ = try? await dbWriter.write { db in
            var row = entry
            try row.save(db)
        }
    }

    public func widgetSnapshotEntry(key: String) async -> WidgetSnapshotEntry? {
        (try? await dbWriter.read { db in
            try WidgetSnapshotEntry.filter(Column("key") == key).fetchOne(db)
        }) ?? nil
    }
}

// MARK: - Test hooks (internal extension — no public API growth for tests)

extension PersistenceStore {
    /// Test-only hard delete of a single message row.
    func deleteMessageForTest(id: UUID) async throws {
        _ = try await dbWriter.write { db in
            try StoredMessage.filter(Column("id") == id).deleteAll(db)
        }
    }
}
