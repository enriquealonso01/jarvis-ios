import Foundation
import GRDB

/// v2 store APIs (plan §5.2 completeness): projects / runs / run_steps /
/// recordings / transcript_segments persistence + transcript FTS search +
/// message server-sync (serverId / pendingSync) round-trip. Additive —
/// lives in its own file so the Item 1 core store file stays untouched.
extension PersistenceStore {
    // MARK: - Projects

    public func upsert(_ project: StoredProject) async {
        _ = try? await dbWriter.write { db in
            var row = project
            try row.save(db)
        }
    }

    public func getProject(id: UUID) async -> StoredProject? {
        (try? await dbWriter.read { db in
            try StoredProject.filter(Column("id") == id).fetchOne(db)
        }) ?? nil
    }

    public func projects(limit: Int = 200) async -> [StoredProject] {
        (try? await dbWriter.read { db in
            try StoredProject
                .order(Column("updated_at").desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }

    /// Item 3 (#2): pinned projects, most recently updated first (sidebar
    /// Pinned mixes these with pinned conversations).
    public func pinnedProjects(limit: Int = 50) async -> [StoredProject] {
        (try? await dbWriter.read { db in
            try StoredProject
                .filter(Column("pinned") == true)
                .order(Column("updated_at").desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }

    // MARK: - Runs + steps

    @discardableResult
    public func upsert(_ run: StoredRun) async -> StoredRun? {
        try? await dbWriter.write { db in
            var row = run
            try row.save(db)
            return row
        }
    }

    public func getRun(id: UUID) async -> StoredRun? {
        (try? await dbWriter.read { db in
            try StoredRun.filter(Column("id") == id).fetchOne(db)
        }) ?? nil
    }

    public func runs(conversationID: UUID? = nil, limit: Int = 200) async -> [StoredRun] {
        (try? await dbWriter.read { db in
            var request = StoredRun.order(Column("created_at").desc).limit(limit)
            if let conversationID {
                request = StoredRun
                    .filter(Column("conversation_id") == conversationID)
                    .order(Column("created_at").desc)
                    .limit(limit)
            }
            return try request.fetchAll(db)
        }) ?? []
    }

    /// Insert one step of a run; `stepOrder` pins its position.
    @discardableResult
    public func addRunStep(_ step: StoredRunStep) async -> StoredRunStep? {
        try? await dbWriter.write { db in
            var row = step
            try row.insert(db)
            return row
        }
    }

    /// Steps of a run, in `step_order`.
    public func runSteps(runID: UUID) async -> [StoredRunStep] {
        (try? await dbWriter.read { db in
            try StoredRunStep
                .filter(Column("run_id") == runID)
                .order(Column("step_order").asc, Column("id").asc)
                .fetchAll(db)
        }) ?? []
    }

    // MARK: - Recordings + transcript segments

    @discardableResult
    public func upsert(_ recording: StoredRecording) async -> StoredRecording? {
        try? await dbWriter.write { db in
            var row = recording
            try row.save(db)
            return row
        }
    }

    public func getRecording(id: UUID) async -> StoredRecording? {
        (try? await dbWriter.read { db in
            try StoredRecording.filter(Column("id") == id).fetchOne(db)
        }) ?? nil
    }

    /// Append one transcript segment (FTS5 trigger keeps the index in sync).
    @discardableResult
    public func addTranscriptSegment(_ segment: StoredTranscriptSegment) async -> StoredTranscriptSegment? {
        try? await dbWriter.write { db in
            var row = segment
            try row.insert(db)
            return row
        }
    }

    public func transcriptSegments(recordingID: UUID) async -> [StoredTranscriptSegment] {
        (try? await dbWriter.read { db in
            try StoredTranscriptSegment
                .filter(Column("recording_id") == recordingID)
                .order(Column("created_at").asc, Column("id").asc)
                .fetchAll(db)
        }) ?? []
    }

    /// Unified-search counterpart for transcripts: FTS5 MATCH over segment
    /// text, rank-ordered (§5.2 "FTS5 over message bodies + transcript
    /// segments").
    public func searchTranscriptSegments(matching query: String, limit: Int = 50) async throws -> [StoredTranscriptSegment] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return try await dbWriter.read { db in
            let sql = """
                SELECT transcript_segments.* FROM transcript_segments
                JOIN transcript_segments_fts
                  ON transcript_segments_fts.rowid = transcript_segments.rowid
                WHERE transcript_segments_fts MATCH ?
                ORDER BY rank
                LIMIT ?
                """
            return try StoredTranscriptSegment
                .fetchAll(db, sql: sql, arguments: [FTS5Pattern(rawPattern: query), limit])
        }
    }

    // MARK: - Message server-sync (serverId / pendingSync)

    /// Stamp the server-assigned ID on a delivered message and clear its
    /// pending-sync flag. Returns the updated row (nil if unknown id).
    @discardableResult
    public func markMessageSynced(id: UUID, serverID: String) async -> StoredMessage? {
        try? await dbWriter.write { db in
            guard var row = try StoredMessage
                .filter(Column("id") == id)
                .fetchOne(db) else { return nil }
            row.serverID = serverID
            row.pendingSync = false
            try row.update(db)
            return row
        }
    }

    /// Messages still awaiting their server ACK, FIFO by creation.
    public func pendingSyncMessages(conversationID: UUID? = nil) async -> [StoredMessage] {
        (try? await dbWriter.read { db in
            var request = StoredMessage
                .filter(Column("pending_sync") == true)
                .order(Column("created_at").asc, Column("id").asc)
            if let conversationID {
                request = StoredMessage
                    .filter(Column("conversation_id") == conversationID)
                    .filter(Column("pending_sync") == true)
                    .order(Column("created_at").asc, Column("id").asc)
            }
            return try request.fetchAll(db)
        }) ?? []
    }

    /// Lookup by server-assigned ID (dedupe on reconnect/replay).
    public func getMessage(serverID: String) async -> StoredMessage? {
        (try? await dbWriter.read { db in
            try StoredMessage.filter(Column("server_id") == serverID).fetchOne(db)
        }) ?? nil
    }
}
