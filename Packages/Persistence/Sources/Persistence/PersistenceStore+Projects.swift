import Foundation
import GRDB

/// Item 10 store APIs (UI-Expansion package §05 "Projects"): Project Home
/// reads — the project-scoped conversation query, project instructions,
/// sources CRUD — plus the pure scoping contract the QA suite pins
/// (`ProjectScope.isMember` is THE single decision function; every scoped
/// read in the app composes it, so a chat in project A can never surface
/// under project B).
///
/// Isolation rule (zero cross-project leakage): every conversation query
/// that returns project chats runs
/// `project_id == <id> AND archived == false` — a single indexed filter on
/// the row. Ungrouped chats (projectID nil) and other projects' rows are
/// excluded by construction; the tester QA pins the full matrix.
extension PersistenceStore {

    // MARK: - Project-scoped conversations (isolation boundary)

    /// The project's chats: `project_id == projectID AND archived == false`,
    /// newest first (updatedAt, then createdAt, then id — the house order).
    /// THE Project Home list. Every scoped surface reads through here; ad-hoc
    /// filtering of the global lists is forbidden (Item 10 QA law).
    public func conversations(projectID: UUID, limit: Int = 200) async -> [StoredConversation] {
        (try? await dbWriter.read { db in
            try StoredConversation
                .filter(Column("project_id") == projectID)
                .filter(Column("archived") == false)
                .order(Column("updated_at").desc, Column("created_at").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }

    /// Per-project counts in one query (Project Home header line).
    public func projectChatCounts() async -> [UUID: Int] {
        let rows = (try? await dbWriter.read { db in
            try Row.fetchAll(db, sql: """
                SELECT project_id, COUNT(*) AS n FROM conversations
                WHERE project_id IS NOT NULL AND archived = 0
                GROUP BY project_id
                """)
        }) ?? []
        var counts: [UUID: Int] = [:]
        for row in rows {
            guard let id: UUID = row["project_id"] else { continue }
            counts[id] = row["n"]
        }
        return counts
    }

    // MARK: - Project mutations (Project Home settings)

    /// Rename a project (whitespace-only rejected). Returns true on write.
    @discardableResult
    public func renameProject(id: UUID, to name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return await updateProject(id: id) { $0.name = trimmed }
    }

    /// Replace the project instructions (Project Home edit; stored verbatim,
    /// whitespace trimmed — empty string clears). Returns true on write.
    @discardableResult
    public func setProjectInstructions(id: UUID, to instructions: String) async -> Bool {
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return await updateProject(id: id) { $0.instructions = trimmed }
    }

    /// Archive a project: the row stays (unarchive = flip the flag back),
    /// but it leaves the sidebar tree + Project Home surfaces (both filter
    /// `archived == false`). Its conversations are untouched. Returns true
    /// on write; false when the project row is gone.
    @discardableResult
    public func setProjectArchived(_ archived: Bool, id: UUID) async -> Bool {
        await updateProject(id: id) { $0.archived = archived }
    }

    /// Shared read-modify-write; false when the project row is gone.
    private func updateProject(id: UUID, _ mutate: (inout StoredProject) -> Void) async -> Bool {
        guard var project = await getProject(id: id) else { return false }
        mutate(&project)
        project.updatedAt = Date()
        await upsert(project)
        return true
    }

    /// Delete a project row outright (CRUD primitive; sources cascade via
    /// the FK). Used by Project Home's ghost-state QA path.
    @discardableResult
    public func deleteProject(id: UUID) async -> Bool {
        guard let deleted = try? await dbWriter.write({ db in
            try StoredProject.filter(Column("id") == id).deleteAll(db)
        }) else { return false }
        return deleted > 0
    }

    // MARK: - Sources (Project Home list)

    /// Attach one source (file path or link) to the project, appended at the
    /// end of the list. The project must exist (orphan rows impossible).
    @discardableResult
    public func addProjectSource(_ source: StoredProjectSource) async -> StoredProjectSource? {
        guard await getProject(id: source.projectID) != nil else { return nil }
        let nextOrder = await projectSources(projectID: source.projectID).count
        // Adjust BEFORE the write closure: a @Sendable closure cannot capture
        // a mutated local (Swift 6) — hand it an immutable copy and shadow
        // the mutable var inside (the house GRDB-write pattern).
        var adjusted = source
        if adjusted.displayOrder == 0 { adjusted.displayOrder = nextOrder }
        let toSave = adjusted
        let saved = (try? await dbWriter.write { db in
            var row = toSave
            try row.save(db)
            return row
        }) ?? nil
        if saved != nil { await touch(projectID: source.projectID) }
        return saved
    }

    /// The project's sources in display order. Scoped by construction —
    /// a source row carries exactly one project_id.
    public func projectSources(projectID: UUID) async -> [StoredProjectSource] {
        (try? await dbWriter.read { db in
            try StoredProjectSource
                .filter(Column("project_id") == projectID)
                .order(Column("display_order").asc, Column("created_at").asc, Column("id").asc)
                .fetchAll(db)
        }) ?? []
    }

    /// Remove one source by id; only removes when it belongs to `projectID`
    /// (the scoped identity check — a stale/foreign id is a no-op, never a
    /// cross-project delete).
    @discardableResult
    public func removeProjectSource(id: UUID, projectID: UUID) async -> Bool {
        let deleted = (try? await dbWriter.write { db in
            try StoredProjectSource
                .filter(Column("id") == id)
                .filter(Column("project_id") == projectID)
                .deleteAll(db)
        }) ?? 0
        if deleted > 0 { await touch(projectID: projectID) }
        return deleted > 0
    }

    private func touch(projectID: UUID) async {
        _ = await updateProject(id: projectID) { $0.pinned = $0.pinned }
    }
}

// MARK: - Pure scoping contract (headless-testable; pinned by Item 10 QA)

/// The single source of truth for "is this conversation in this project?" —
/// every Project Home / project-scoped surface composes this function, so
/// the isolation rule has exactly one implementation to QA-pin.
public enum ProjectScope {
    /// A conversation belongs to a project iff its `projectID` equals the
    /// project's id — nil (ungrouped) is NEVER a member, a different id is
    /// NEVER a member, and membership does not depend on pin/archive state.
    public static func isMember(_ conversationProjectID: UUID?, of projectID: UUID) -> Bool {
        conversationProjectID == projectID
    }

    /// Filter a conversation list down to one project's members (order kept).
    public static func filter(_ conversations: [StoredConversation], to projectID: UUID) -> [StoredConversation] {
        conversations.filter { isMember($0.projectID, of: projectID) }
    }
}
