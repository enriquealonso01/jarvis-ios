import Foundation
import Persistence

/// Sidebar view model (plan §5.1: `@MainActor @Observable`, all I/O in the
/// store actor). Builds Pinned / Projects / Recents from the Item 1
/// PersistenceStore and executes the UI Law §8 list mechanics (pin/unpin,
/// rename, archive, delete) straight through store calls.
@MainActor
@Observable
public final class SidebarViewModel {

    // MARK: - Snapshot state (read by the view)

    /// Pinned chats + pinned projects, interleaved, newest first.
    public private(set) var pinnedEntries: [SidebarEntry] = []
    /// Projects with their chats attached, pinned projects first.
    public private(set) var projectGroups: [SidebarProjectGroup] = []
    /// All non-archived conversations, newest first (Recents source).
    public private(set) var recentChats: [StoredConversation] = []
    /// Recents grouped by project (projectID nil = ungrouped), group order
    /// follows each group's newest chat.
    public private(set) var recentsGroupedByProject: [SidebarRecentsGroup] = []
    /// True once the first load completed (drives the empty state).
    public private(set) var loaded = false

    // MARK: - Presentation state

    /// Currently expanded project sections (DisclosureGroups).
    public var expandedProjects: Set<UUID> = []

    private let store: PersistenceStore

    public init(store: PersistenceStore) {
        self.store = store
    }

    // MARK: - Loading

    /// Reload everything the sidebar shows. Cheap (indexed reads, limits);
    /// call on appear and after any mutation.
    public func load() async {
        async let pinnedConvs = store.conversations(limit: 200)
        async let projects = store.projects(limit: 200)

        let allConversations = await pinnedConvs
        let allProjects = await projects

        let visible = allConversations.filter { !$0.archived }
        let visibleProjects = allProjects

        // Group chats under their project once (O(n)).
        var chatsByProject: [UUID: [StoredConversation]] = [:]
        for conversation in visible {
            guard let projectID = conversation.projectID else { continue }
            chatsByProject[projectID, default: []].append(conversation)
        }

        // --- Pinned: chats + projects mixed, newest first (UI Law §1).
        let pinnedChats = visible
            .filter(\.pinned)
            .map { conversation in
                SidebarEntry(
                    kind: .chat(id: conversation.id),
                    title: conversation.title,
                    subtitle: conversation.lastMessagePreview,
                    updatedAt: conversation.updatedAt
                )
            }
        let pinnedProjects = visibleProjects
            .filter(\.pinned)
            .map { project in
                SidebarEntry(
                    kind: .project(id: project.id),
                    title: project.name,
                    subtitle: nil,
                    updatedAt: project.updatedAt
                )
            }
        pinnedEntries = (pinnedChats + pinnedProjects)
            .sorted { $0.updatedAt > $1.updatedAt }

        // --- Projects: expandable rows, pinned first, then newest.
        projectGroups = visibleProjects
            .sorted {
                if $0.pinned != $1.pinned { return $0.pinned }
                return $0.updatedAt > $1.updatedAt
            }
            .map { project in
                SidebarProjectGroup(
                    project: project,
                    conversations: (chatsByProject[project.id] ?? [])
                        .sorted { $0.updatedAt > $1.updatedAt }
                )
            }

        // --- Recents: combined chronological, newest first.
        recentChats = visible.sorted { $0.updatedAt > $1.updatedAt }

        // --- Recents grouped by project (groupable per UI Law §1).
        recentsGroupedByProject = Self.groupedByProject(
            chats: recentChats,
            projects: visibleProjects
        )

        loaded = true
    }

    /// Pure grouping — unit-testable without a store. Keeps only non-empty
    /// groups; ungrouped chats collapse into one trailing group.
    public static func groupedByProject(
        chats: [StoredConversation],
        projects: [StoredProject]
    ) -> [SidebarRecentsGroup] {
        let names = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.name) })
        var buckets: [UUID?: [StoredConversation]] = [:]
        for chat in chats {
            buckets[chat.projectID, default: []].append(chat)
        }
        // Group order = order of each group's newest chat (chats arrive
        // newest-first, so first appearance order is the group order).
        var order: [UUID?] = []
        for chat in chats where !order.contains(where: { $0 == chat.projectID }) {
            order.append(chat.projectID)
        }
        return order.compactMap { projectID in
            guard let chats = buckets[projectID], !chats.isEmpty else { return nil }
            return SidebarRecentsGroup(
                projectID: projectID,
                projectName: projectID.flatMap { names[$0] },
                conversations: chats
            )
        }
    }

    // MARK: - List mechanics (UI Law §8; Item 5 fleshes out the menus)

    public func setPinned(_ pinned: Bool, conversationID: UUID) async {
        guard var conversation = await store.get(id: conversationID) else { return }
        conversation.pinned = pinned
        await store.upsert(conversation)
        await load()
    }

    public func setPinned(_ pinned: Bool, projectID: UUID) async {
        guard var project = await store.getProject(id: projectID) else { return }
        project.pinned = pinned
        await store.upsert(project)
        await load()
    }

    public func rename(conversationID: UUID, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var conversation = await store.get(id: conversationID) else { return }
        conversation.title = trimmed
        await store.upsert(conversation)
        await load()
    }

    /// Archive: no confirmation, stays searchable (UI Law §8).
    public func archive(conversationID: UUID) async {
        guard var conversation = await store.get(id: conversationID) else { return }
        conversation.archived = true
        await store.upsert(conversation)
        await load()
    }

    /// Unarchive: archive's inverse (Item 5 QA defect #2) — the row returns
    /// to Recents/Pinned on the next load (§8: archived stays searchable;
    /// unarchive is how search results come back to the lists).
    public func unarchive(conversationID: UUID) async {
        guard var conversation = await store.get(id: conversationID) else { return }
        conversation.archived = false
        await store.upsert(conversation)
        await load()
    }

    /// Delete: the UI wraps this in a confirmation (UI Law §8).
    @discardableResult
    public func delete(conversationID: UUID) async -> Bool {
        let deleted = await store.deleteConversation(id: conversationID)
        if deleted { await load() }
        return deleted
    }
}
