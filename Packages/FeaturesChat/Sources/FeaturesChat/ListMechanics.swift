import Foundation
import Persistence

// MARK: - Item 5: list-mechanics pure-logic seam (feature #5, UI Law §8)
//
// The §8 row-mechanics rules (auto-title, rename, pin, archive, delete)
// are pure functions in Persistence (ListMechanicsEngine) so any store
// consumer can decide before writing. This shim exposes exactly those
// decision points on the view-model-facing type, keeping FeaturesChat's
// view models view-free of rule math. Zero state — a namespace, not a
// machine.
@MainActor
public enum ListMechanics {

    // MARK: Auto-title (after the first exchange)

    /// True when the conversation should retitle itself after this message
    /// lands: still on a default title + the message is from the user.
    public static func shouldAutoTitle(currentTitle: String, messageRole: MessageRole) -> Bool {
        ListMechanicsEngine.shouldAutoTitle(currentTitle: currentTitle, messageRole: messageRole)
    }

    /// True for default/placeholder titles ("New chat", case-insensitive,
    /// or blank).
    public static func isDefaultTitle(_ title: String) -> Bool {
        ListMechanicsEngine.isDefaultTitle(title)
    }

    /// The derived title from the first user message (first line, trimmed,
    /// clamped to `ListMechanicsEngine.maxAutoTitleLength`).
    public static func autoTitle(for messageText: String) -> String {
        ListMechanicsEngine.autoTitle(for: messageText)
    }

    // MARK: Row menu + swipe models (UI Law §8)

    /// Long-press menu: Rename, Pin/Unpin, Archive, Delete (red) — in order.
    public static func menuActions(for conversation: StoredConversation) -> [RowMenuAction] {
        ListMechanicsEngine.menuActions(for: conversation)
    }

    /// Swipe-left actions: exactly [.delete] (ChatGPT grammar).
    public static func swipeActions(for conversation: StoredConversation) -> [RowSwipeAction] {
        ListMechanicsEngine.swipeActions(for: conversation)
    }

    /// Rename gate: blank (whitespace-only) names never land; a no-change
    /// rename is a no-op.
    public static func isValidRename(currentTitle: String, newTitle: String) -> Bool {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != currentTitle
    }
}
