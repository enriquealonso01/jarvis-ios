import Foundation

// MARK: - Item 5: List mechanics (feature #5, P0 — UI Law §8)
//
// Pure-logic decision layer for the sidebar's conversation-row mechanics:
// auto-title, rename, pin, archive, delete. Every decision is a total
// function over Sendable inputs; the callers (SidebarViewModel / the app
// shell) execute the returned effect against the store (see
// PersistenceStore+ListMechanics). No SwiftUI, no UIKit, no I/O in here —
// this file is the unit-tested core.
//
// UI Law §8 contract:
//   • Conversations auto-title after the first exchange (first USER
//     message, per ChatGPT grammar; assistant-first rows never title).
//   • Long-press row menu: Rename, Pin, Archive, Delete (Delete is the
//     red/confirmed one — the confirmation gate lives in the view layer;
//     the engine just encodes it as the destructive action).
//   • Swipe left: Delete.
//   • Archive: no confirmation; archived leaves every section but stays
//     searchable (Item 6 server search reads the same rows).

/// One row-mechanics decision: what should happen to the store after a
/// user action or a message write. Executed by the caller.
public enum ListMechanicsEffect: Sendable, Equatable {
    /// Write the auto-titled / renamed row back (upsert).
    case updateTitle(conversationID: UUID, title: String)
    /// Flip the pinned flag to this value (upsert).
    case setPinned(conversationID: UUID, pinned: Bool)
    /// Flip the archived flag to this value (upsert).
    case setArchived(conversationID: UUID, archived: Bool)
    /// Delete the conversation row entirely (messages cascade via FK).
    case delete(conversationID: UUID)
    /// Nothing to do (guarded no-op — not an error).
    case none
}

/// Pure decision engine for §8 row mechanics. Stateless so every rule is
/// directly assertable; what the row renders (menu contents, swipe set) is
/// exposed as static functions too.
public enum ListMechanicsEngine {

    // MARK: Auto-title (after the first exchange)

    /// Should this conversation title itself from the first user message?
    /// Exactly when it still carries a default/placeholder title and a
    /// first user message just landed.
    public static func shouldAutoTitle(currentTitle: String, messageRole: MessageRole) -> Bool {
        isDefaultTitle(currentTitle) && messageRole == .user
    }

    /// True when the title is a default/placeholder value (never auto-title
    /// over a user-chosen name — rename wins permanently). Empty titles are
    /// treated as defaults (placeholder typo-safety).
    public static func isDefaultTitle(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return trimmed.caseInsensitiveCompare("New chat") == .orderedSame
    }

    /// Derive the auto-title from the first user message: first line,
    /// whitespace-trimmed, clamped to `maxAutoTitleLength` (no ellipsis —
    /// the sidebar row already lineLimits(1)).
    public static func autoTitle(for messageText: String) -> String {
        let firstLine = messageText
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? messageText
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxAutoTitleLength else { return trimmed }
        return String(trimmed.prefix(maxAutoTitleLength))
    }

    /// Title clamp (ChatGPT-grammar length; the sidebar row is one line).
    public static let maxAutoTitleLength = 40

    /// Full rule for a just-persisted message: the effect to run (or .none).
    public static func effect(forMessageRole role: MessageRole,
                              currentTitle: String,
                              conversationID: UUID,
                              messageText: String) -> ListMechanicsEffect {
        guard shouldAutoTitle(currentTitle: currentTitle, messageRole: role) else { return .none }
        return .updateTitle(conversationID: conversationID, title: autoTitle(for: messageText))
    }

    // MARK: Rename (long-press menu)

    /// Rename effect: whitespace-only names are rejected (a no-op — the row
    /// keeps its current title rather than going blank), and a no-change
    /// rename is a no-op.
    public static func renameEffect(conversationID: UUID,
                                    currentTitle: String,
                                    newTitle: String) -> ListMechanicsEffect {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != currentTitle else { return .none }
        return .updateTitle(conversationID: conversationID, title: trimmed)
    }

    // MARK: Pin / Archive / Delete (menu + swipe)

    public static func pinEffect(conversationID: UUID, currentlyPinned: Bool) -> ListMechanicsEffect {
        .setPinned(conversationID: conversationID, pinned: !currentlyPinned)
    }

    /// Archive always runs with no confirmation (UI Law §8) — the effect is
    /// unconditional; archived rows leave every sidebar section but stay in
    /// the store for search (Item 6).
    public static func archiveEffect(conversationID: UUID) -> ListMechanicsEffect {
        .setArchived(conversationID: conversationID, archived: true)
    }

    /// Delete from the long-press menu: the view layer confirms BEFORE this
    /// effect is produced (the engine encodes the contract; the view encodes
    /// the red + confirmation UI).
    public static func deleteEffect(conversationID: UUID) -> ListMechanicsEffect {
        .delete(conversationID: conversationID)
    }

    /// Swipe left → delete — the same semantics as the menu delete (UI Law
    /// §8 gives swipe no separate behavior).
    public static func swipeDeleteEffect(conversationID: UUID) -> ListMechanicsEffect {
        .delete(conversationID: conversationID)
    }

    // MARK: Menu + swipe models (what the row renders)

    /// The long-press menu contents, in ChatGPT-grammar order. Delete is
    /// flagged destructive (red + confirmation in the view layer).
    public static func menuActions(for conversation: StoredConversation) -> [RowMenuAction] {
        [
            RowMenuAction(kind: .rename, isDestructive: false),
            RowMenuAction(kind: conversation.pinned ? .unpin : .pin, isDestructive: false),
            RowMenuAction(kind: .archive, isDestructive: false),
            RowMenuAction(kind: .delete, isDestructive: true),
        ]
    }

    /// Swipe actions for this row: swipe left = Delete only (pin/archive
    /// stay menu-only — ChatGPT grammar).
    public static func swipeActions(for conversation: StoredConversation) -> [RowSwipeAction] {
        [.delete]
    }
}

/// One long-press menu entry (UI Law §8 order: Rename, Pin/Unpin, Archive,
/// Delete).
public struct RowMenuAction: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case rename, pin, unpin, archive, delete
    }

    public let kind: Kind
    public let isDestructive: Bool
    public var id: Kind { kind }

    public init(kind: Kind, isDestructive: Bool) {
        self.kind = kind
        self.isDestructive = isDestructive
    }
}

/// Swipe-left action set (currently exactly `.delete`).
public enum RowSwipeAction: Sendable, Equatable {
    case delete
}
