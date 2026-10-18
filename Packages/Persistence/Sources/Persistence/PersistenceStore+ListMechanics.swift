import Foundation
import GRDB
import Persistence

// MARK: - Item 5: list-mechanics execution layer (feature #5, UI Law §8)
//
// Store-backed executor for the pure `ListMechanicsEngine` decisions: one
// async entry point per §8 mechanic, each writing through the real GRDB
// store before returning (local-first, same contract as Items 1–4). The
// pure engine stays unit-testable without I/O; this extension is the thin,
// typed seam between decisions and rows.

extension PersistenceStore {

    /// Apply one list-mechanics effect. Returns the effect back (so callers
    /// can assert/log what ran); unknown-row effects degrade to no-ops
    /// (never fatal).
    @discardableResult
    public func apply(_ effect: ListMechanicsEffect) async -> ListMechanicsEffect {
        switch effect {
        case .updateTitle(let id, let title):
            await renameConversation(id: id, title: title)
        case .setPinned(let id, let pinned):
            await setPinned(pinned, conversationID: id)
        case .setArchived(let id, let archived):
            await setArchived(archived, conversationID: id)
        case .delete(let id):
            _ = await deleteConversation(id: id)
        case .none:
            break
        }
        return effect
    }

    /// Rename write-through: preserves the row's other fields, and is a
    /// no-op for blank names or unchanged titles.
    public func renameConversation(id: UUID, title: String) async {
        guard var conversation = await get(id: id) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != conversation.title else { return }
        conversation.title = trimmed
        await upsert(conversation)
    }

    /// Pin write-through used by the §8 effects (row survives; only delete
    /// removes it).
    public func setPinned(_ pinned: Bool, conversationID: UUID) async {
        guard var conversation = await get(id: conversationID) else { return }
        conversation.pinned = pinned
        await upsert(conversation)
    }

    /// Archive write-through (UI Law §8: no confirmation; the row stays in
    /// the store — searchable by Item 6 — but leaves every sidebar section,
    /// because every section query filters `archived == false`).
    public func setArchived(_ archived: Bool, conversationID: UUID) async {
        guard var conversation = await get(id: conversationID) else { return }
        conversation.archived = archived
        await upsert(conversation)
    }

    /// Auto-title hook: after a message write, apply the §8 first-exchange
    /// rule to the conversation row. Call after upserting a user message.
    /// Returns the new title, or nil when the rule didn't fire.
    @discardableResult
    public func applyAutoTitleIfFirstExchange(conversationID: UUID,
                                              messageRole: MessageRole,
                                              messageText: String) async -> String? {
        guard let conversation = await get(id: conversationID),
              ListMechanicsEngine.shouldAutoTitle(
                  currentTitle: conversation.title, messageRole: messageRole)
        else { return nil }
        let title = ListMechanicsEngine.autoTitle(for: messageText)
        await renameConversation(id: conversationID, title: title)
        return title
    }

    /// All conversations including archived ones (UI Law §8: archived rows
    /// "stay searchable" — Item 6's unified search reads this; the sidebar
    /// sections never do).
    public func conversationsIncludingArchived(limit: Int = 200) async -> [StoredConversation] {
        (try? await dbWriter.read { db in
            try StoredConversation
                .order(Column("updated_at").desc)
                .limit(limit)
                .fetchAll(db)
        }) ?? []
    }
}
