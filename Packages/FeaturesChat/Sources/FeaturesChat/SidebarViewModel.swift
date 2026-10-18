import Foundation
import Persistence
import DesignSystem

/// Item 3 sidebar view model (feature #2, P0) — store-backed, pure logic.
///
/// Contract (pinned by Item3SidebarCorrectnessQATests):
///   • pinned / recents split: pinned rows live ONLY in `pinned`, recents
///     are strictly newest-first and exclude pinned + archived;
///   • pagination: `recentsPageSize` per page, `loadMoreRecents()` appends
///     exactly the remaining rows, past-end load is a no-op;
///   • pin/unpin/archive write through the real store, then re-load;
///   • search filter: client-side, case-insensitive over title + preview,
///     whitespace-only = empty = unfiltered;
///   • project tree: a chat in project A NEVER appears under project B
///     (including across pin and newChat mutations);
///   • new chat: creates a store row, selects itself, leads recents;
///   • state restoration: open/closed + projectsExpanded + last selection
///     survive a store re-init via the KV surface; dangling selection → nil.
@MainActor
public final class SidebarViewModel: ObservableObject {

    // MARK: - Published snapshot state

    /// Pinned conversations, newest first (Pinned section, chats only —
    /// projects pin separately in the tree).
    @Published public private(set) var pinned: [StoredConversation] = []
    /// Recents page accumulator (unpinned, non-archived, newest first).
    @Published public private(set) var recents: [StoredConversation] = []
    /// Project tree: pinned projects first, then newest; each node carries
    /// its non-archived chats, newest first.
    @Published public private(set) var projects: [SidebarProjectNode] = []
    /// More recents pages on the server (limit+1 probe result).
    @Published public private(set) var canLoadMoreRecents = false

    // MARK: - Presentation + restoration state

    /// Slide-over visibility (UI Law §1); persisted across launches.
    @Published public var isOpen = false
    /// Collapsible Projects section (Item 3 §1); persisted across launches.
    @Published public var projectsExpanded = true
    /// Client-side search query (Item 6 replaces this with server search).
    @Published public var searchQuery = "" {
        didSet { recomputeFilter() }
    }
    /// Last selected conversation (drives the chat surface on restore).
    @Published public private(set) var selectedConversationID: UUID?
    /// Settings placeholder sheet (profile row destination).
    @Published public var settingsSheetVisible = false

    /// True once restoreState + first reload completed (drives empty state).
    public private(set) var loaded = false

    /// No-op hook: filtered output is fully derived (see `filteredRecents`
    /// / `filteredProjects`), so query changes recompute on read. Kept as a
    /// call target so `didSet` sites have a single, documented seam.
    private func recomputeFilter() {}

    private let store: PersistenceStore

    public init(store: PersistenceStore) {
        self.store = store
    }

    // MARK: - Derived search output (client-side filter)

    /// Recents filtered by `searchQuery` (title + preview, case-insensitive).
    public var filteredRecents: [StoredConversation] {
        filterConversations(recents)
    }

    /// Project tree narrowed to projects with matching names OR matching
    /// chats; nodes without any match drop out entirely.
    public var filteredProjects: [SidebarProjectNode] {
        let q = normalizedQuery
        guard !q.isEmpty else { return projects }
        return projects.compactMap { node in
            let projectHit = node.project.name.localizedCaseInsensitiveContains(q)
            let chats = filterConversations(node.conversations)
            guard projectHit || !chats.isEmpty else { return nil }
            return SidebarProjectNode(
                project: node.project,
                conversations: projectHit ? node.conversations : chats
            )
        }
    }

    private var normalizedQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func filterConversations(_ rows: [StoredConversation]) -> [StoredConversation] {
        let q = normalizedQuery
        guard !q.isEmpty else { return rows }
        return rows.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || ($0.lastMessagePreview?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    // MARK: - Loading

    /// Full reload: pinned, first recents page, project tree. Call on open
    /// and after any mutation.
    public func reload() async {
        pinned = await store.conversationsPinned()
        recents = []
        let page = await store.conversationsPage(offset: 0, limit: Tokens.Sidebar.recentsPageSize)
        recents = page.rows
        canLoadMoreRecents = page.hasMore
        await loadProjects()
        recomputeFilter()
        loaded = true
    }

    /// Append the next recents page (no-op past the end, idempotent).
    public func loadMoreRecents() async {
        guard canLoadMoreRecents else { return }
        let page = await store.conversationsPage(
            offset: recents.count, limit: Tokens.Sidebar.recentsPageSize
        )
        // Offset pagination is safe here: mutations reload from zero, so a
        // mid-pagination upsert cannot shift the window on a live cursor.
        recents += page.rows
        canLoadMoreRecents = page.hasMore
    }

    /// Project tree from the store: pinned first, then newest; each node's
    /// chats are non-archived, newest first.
    private func loadProjects() async {
        let allProjects = await store.projects(limit: 200)
        let visible = allProjects.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.updatedAt > $1.updatedAt
        }
        guard !visible.isEmpty else {
            projects = []
            return
        }
        // Chats per project from the conversations table (non-archived).
        // Read via pinned + page walk so archived rows never enter the tree.
        var byProject: [UUID: [StoredConversation]] = [:]
        var conversations: [StoredConversation] = await store.conversationsPinned(limit: 1_000)
        var cursor = 0
        var walking = true
        while walking {
            let page = await store.conversationsPage(offset: cursor, limit: 1_000)
            conversations += page.rows
            walking = page.hasMore
            cursor += page.rows.count
        }
        for conversation in conversations {
            guard let projectID = conversation.projectID else { continue }
            byProject[projectID, default: []].append(conversation)
        }
        projects = visible.map { project in
            SidebarProjectNode(
                project: project,
                conversations: (byProject[project.id] ?? [])
                    .sorted { $0.updatedAt > $1.updatedAt }
            )
        }
    }

    // MARK: - List mechanics (UI Law §8; write-through, then re-load)

    /// Pin/unpin a conversation (Pinned section membership + store write).
    public func setPinned(_ pinned: Bool, conversationID: UUID) async {
        guard var conversation = await store.get(id: conversationID) else { return }
        conversation.pinned = pinned
        await store.upsert(conversation)
        await reload()
    }

    /// Pin/unpin a project (tree order + store write).
    public func setPinned(_ pinned: Bool, projectID: UUID) async {
        guard var project = await store.getProject(id: projectID) else { return }
        project.pinned = pinned
        await store.upsert(project)
        await loadProjects()
    }

    /// Archive/unarchive (UI Law §8: no confirmation; archived rows leave
    /// every section but stay searchable in Item 6's server search).
    public func setArchived(_ archived: Bool, conversationID: UUID) async {
        guard var conversation = await store.get(id: conversationID) else { return }
        conversation.archived = archived
        await store.upsert(conversation)
        if let selected = selectedConversationID, selected == conversationID, archived {
            // Dangling selection must not survive an archive of its row.
            selectedConversationID = nil
            await persistSelection()
        }
        await reload()
    }

    /// Unarchive: archive's inverse (Item 5 QA defect #2) — symmetric
    /// store write + reload; the row returns to its sections (Item 6
    /// search will route restores through this seam).
    public func unarchive(conversationID: UUID) async {
        await setArchived(false, conversationID: conversationID)
    }

    /// New chat: creates the store row, selects it, leads recents.
    @discardableResult
    public func newChat(projectID: UUID? = nil, title: String = "New chat") async -> StoredConversation {
        var conversation = StoredConversation(
            projectID: projectID,
            title: title,
            updatedAt: Date()
        )
        await store.upsert(conversation)
        await reload()
        selectedConversationID = conversation.id
        await persistSelection()
        return conversation
    }

    // MARK: - Item 5 list mechanics (feature #5, UI Law §8)

    /// Rename via the long-press menu: whitespace-only names are rejected,
    /// a no-change rename is a no-op, real renames write through and reload.
    /// Returns true when a write happened.
    @discardableResult
    public func rename(conversationID: UUID, to newTitle: String) async -> Bool {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let current = await store.get(id: conversationID),
              current.title != trimmed else { return false }
        await store.renameConversation(id: conversationID, title: trimmed)
        await reload()
        return true
    }

    /// Swipe-left delete (UI Law §8). The swipe UI carries the red styling
    /// + confirmation; this is the confirmed execution path: remove the
    /// row, drop selection/restore key if it pointed here, reload.
    public func swipeDelete(conversationID: UUID) async {
        await delete(conversationID: conversationID)
    }

    /// Confirmed delete (long-press menu, after the confirmation dialog).
    /// Archive never routes through here (§8: archive has NO confirmation
    /// and keeps the row; delete is the only destructive mechanic).
    public func delete(conversationID: UUID) async {
        _ = await store.deleteConversation(id: conversationID)
        if selectedConversationID == conversationID {
            selectedConversationID = nil
            await persistSelection()
        }
        await reload()
    }

    /// Auto-title hook for the chat surface: call after persisting a
    /// message in this conversation. Applies the §8 first-exchange rule
    /// (default title + user message → title from that message) and
    /// reloads when a title changed.
    @discardableResult
    public func applyAutoTitleIfFirstExchange(conversationID: UUID,
                                              messageRole: MessageRole,
                                              messageText: String) async -> String? {
        guard let title = await store.applyAutoTitleIfFirstExchange(
            conversationID: conversationID,
            messageRole: messageRole,
            messageText: messageText)
        else { return nil }
        await reload()
        return title
    }

    // MARK: - Selection + presentation

    /// Select a conversation (row tap) — persists for restoration before
    /// returning (deterministic for the restore contract).
    public func select(conversationID: UUID) async {
        selectedConversationID = conversationID
        await persistSelection()
    }

    /// Slide-over open/close — persists across launches (Item 3 §4).
    /// Awaitable: the write-through completes before this returns.
    public func setOpen(_ open: Bool) async {
        isOpen = open
        await store.setAppState(open, key: Tokens.Sidebar.Keys.sidebarOpen)
    }

    /// Projects section collapse — persists across launches (Item 3 §1).
    public func setProjectsExpanded(_ expanded: Bool) async {
        projectsExpanded = expanded
        await store.setAppState(expanded, key: Tokens.Sidebar.Keys.projectsExpanded)
    }

    /// Cold-launch restore: open/closed, projects collapse, last selection.
    /// A selection whose row no longer exists restores to nil.
    public func restoreState() async {
        isOpen = (await store.appState(Bool.self, key: Tokens.Sidebar.Keys.sidebarOpen)) ?? false
        projectsExpanded = (await store.appState(Bool.self, key: Tokens.Sidebar.Keys.projectsExpanded)) ?? true
        let restored = await store.appState(String.self, key: Tokens.Sidebar.Keys.lastSelection)
        if let uuidString = restored, let id = UUID(uuidString: uuidString),
           await store.get(id: id) != nil {
            selectedConversationID = id
        } else {
            selectedConversationID = nil
        }
    }

    private func persistSelection() async {
        guard let selectedConversationID else {
            await store.removeAppState(key: Tokens.Sidebar.Keys.lastSelection)
            return
        }
        await store.setAppState(
            selectedConversationID.uuidString,
            key: Tokens.Sidebar.Keys.lastSelection
        )
    }
}

/// One project node in the sidebar tree: the project + its non-archived
/// chats, newest first. Equatable for SwiftUI ForEach stability.
public struct SidebarProjectNode: Identifiable, Equatable {
    public let project: StoredProject
    public var conversations: [StoredConversation]

    public var id: UUID { project.id }

    public init(project: StoredProject, conversations: [StoredConversation]) {
        self.project = project
        self.conversations = conversations
    }
}
