import XCTest
import Persistence

// MARK: - Item 5 BUILDER tests: list mechanics (feature #5, UI Law §8)
//
// Two layers, both pure-logic / store-backed with no UIKit:
//   1. ListMechanicsEngine — the pure decision rules (auto-title, rename
//      gates, pin/archive/delete effects, menu + swipe models).
//   2. PersistenceStore+ListMechanics — the write-through execution seam
//      over a real in-memory GRDB store (rename/pin/archive/delete round-
//      trips + the auto-title hook), matching the Item 1–4 store-test
//      pattern.
final class Item5ListMechanicsTests: XCTestCase {

    // MARK: Helpers

    private func conv(
        _ title: String = "New chat",
        pinned: Bool = false,
        archived: Bool = false,
        updatedAt: Date = Date(timeIntervalSince1970: 100)
    ) -> StoredConversation {
        StoredConversation(
            title: title, updatedAt: updatedAt,
            pinned: pinned, archived: archived
        )
    }

    private func makeStore() -> PersistenceStore { PersistenceStore() }

    // MARK: 1. Auto-title rule

    func testAutoTitleFiresOnlyForFirstUserExchangeOnDefaultTitle() {
        // Fires: default title + user message.
        XCTAssertTrue(ListMechanicsEngine.shouldAutoTitle(currentTitle: "New chat", messageRole: .user))
        // Never fires: assistant/tool/system messages (first EXCHANGE means
        // the user's first message drives the title — ChatGPT grammar).
        XCTAssertFalse(ListMechanicsEngine.shouldAutoTitle(currentTitle: "New chat", messageRole: .assistant))
        XCTAssertFalse(ListMechanicsEngine.shouldAutoTitle(currentTitle: "New chat", messageRole: .tool))
        XCTAssertFalse(ListMechanicsEngine.shouldAutoTitle(currentTitle: "New chat", messageRole: .system))
        // Never fires once the title is user-chosen (rename wins forever).
        XCTAssertFalse(ListMechanicsEngine.shouldAutoTitle(currentTitle: "Krendora orders", messageRole: .user))
    }

    func testDefaultTitleDetection() {
        XCTAssertTrue(ListMechanicsEngine.isDefaultTitle("New chat"))
        XCTAssertTrue(ListMechanicsEngine.isDefaultTitle("new CHAT"), "case-insensitive")
        XCTAssertTrue(ListMechanicsEngine.isDefaultTitle("  New chat  "), "whitespace-tolerant")
        XCTAssertTrue(ListMechanicsEngine.isDefaultTitle(""), "blank = default (typo safety)")
        XCTAssertTrue(ListMechanicsEngine.isDefaultTitle("   "))
        XCTAssertFalse(ListMechanicsEngine.isDefaultTitle("New chats"))
        XCTAssertFalse(ListMechanicsEngine.isDefaultTitle("My conversation"))
    }

    func testAutoTitleDerivation() {
        // First line only.
        XCTAssertEqual(
            ListMechanicsEngine.autoTitle(for: "Fix the deploy\nsecond line\nthird"),
            "Fix the deploy")
        // Trimmed.
        XCTAssertEqual(ListMechanicsEngine.autoTitle(for: "   hello world   "), "hello world")
        // Clamped to 40 chars.
        let long = String(repeating: "a", count: 100)
        XCTAssertEqual(ListMechanicsEngine.autoTitle(for: long).count,
                       ListMechanicsEngine.maxAutoTitleLength)
        XCTAssertEqual(ListMechanicsEngine.autoTitle(for: long), String(repeating: "a", count: 40))
        // Exactly 40 stays whole; 41 clamps.
        let exact40 = String(repeating: "b", count: 40)
        XCTAssertEqual(ListMechanicsEngine.autoTitle(for: exact40), exact40)
        XCTAssertEqual(ListMechanicsEngine.autoTitle(for: exact40 + "c").count, 40)
        // Empty text degrades to empty (rename gate will keep it safe).
        XCTAssertEqual(ListMechanicsEngine.autoTitle(for: ""), "")
    }

    func testEffectForMessageCoversAllRolesAndStates() {
        let id = UUID()
        // User + default → title effect.
        XCTAssertEqual(
            ListMechanicsEngine.effect(forMessageRole: .user, currentTitle: "New chat",
                                       conversationID: id, messageText: "Plan my week"),
            .updateTitle(conversationID: id, title: "Plan my week"))
        // Assistant on default → nothing (no title from assistant rows).
        XCTAssertEqual(
            ListMechanicsEngine.effect(forMessageRole: .assistant, currentTitle: "New chat",
                                       conversationID: id, messageText: "Sure thing"),
            .none)
        // User on a renamed conversation → nothing (rename wins).
        XCTAssertEqual(
            ListMechanicsEngine.effect(forMessageRole: .user, currentTitle: "Renamed",
                                       conversationID: id, messageText: "hello"),
            .none)
    }

    // MARK: 2. Rename gates

    func testRenameGates() {
        let id = UUID()
        // Blank/whitespace → no-op (never blank a row's title).
        XCTAssertEqual(ListMechanicsEngine.renameEffect(conversationID: id, currentTitle: "A", newTitle: ""), .none)
        XCTAssertEqual(ListMechanicsEngine.renameEffect(conversationID: id, currentTitle: "A", newTitle: "   "), .none)
        // No-change → no-op.
        XCTAssertEqual(ListMechanicsEngine.renameEffect(conversationID: id, currentTitle: "A", newTitle: "A"), .none)
        // Real rename → update effect with the trimmed title.
        XCTAssertEqual(
            ListMechanicsEngine.renameEffect(conversationID: id, currentTitle: "A", newTitle: "  Budget  "),
            .updateTitle(conversationID: id, title: "Budget"))
    }

    // MARK: 3. Pin / archive / delete effects

    func testPinArchiveDeleteEffects() {
        let id = UUID()
        XCTAssertEqual(ListMechanicsEngine.pinEffect(conversationID: id, currentlyPinned: false),
                       .setPinned(conversationID: id, pinned: true))
        XCTAssertEqual(ListMechanicsEngine.pinEffect(conversationID: id, currentlyPinned: true),
                       .setPinned(conversationID: id, pinned: false))
        XCTAssertEqual(ListMechanicsEngine.archiveEffect(conversationID: id),
                       .setArchived(conversationID: id, archived: true))
        XCTAssertEqual(ListMechanicsEngine.deleteEffect(conversationID: id),
                       .delete(conversationID: id))
        // Swipe-left delete carries the same semantics as the menu delete.
        XCTAssertEqual(ListMechanicsEngine.swipeDeleteEffect(conversationID: id),
                       ListMechanicsEngine.deleteEffect(conversationID: id))
        XCTAssertEqual(ListMechanicsEngine.swipeDeleteEffect(conversationID: id),
                       .delete(conversationID: id))
    }

    // MARK: 4. Menu + swipe models (UI Law §8 order)

    func testMenuOrderAndDestructiveFlags() {
        let unpinned = conv("Chat", pinned: false)
        let actions = ListMechanicsEngine.menuActions(for: unpinned)
        XCTAssertEqual(actions.map(\.kind), [.rename, .pin, .archive, .delete],
                       "UI Law §8 order: Rename, Pin, Archive, Delete")
        XCTAssertEqual(actions.filter(\.isDestructive).map(\.kind), [.delete],
                       "Delete is the only red action")
        // Pinned rows show Unpin, not Pin.
        let pinnedActions = ListMechanicsEngine.menuActions(for: conv("Chat", pinned: true))
        XCTAssertEqual(pinnedActions.map(\.kind), [.rename, .unpin, .archive, .delete])
        // Swipe left = Delete only.
        XCTAssertEqual(ListMechanicsEngine.swipeActions(for: unpinned), [.delete])
    }

    // MARK: 5. Store write-through: rename

    func testStoreRenameRoundTripAndGates() async {
        let store = makeStore()
        let row = conv("Before")
        await store.upsert(row)

        await store.renameConversation(id: row.id, title: "After")
        let afterRename = await store.get(id: row.id)?.title
        XCTAssertEqual(afterRename, "After", "rename writes through")

        // Blank rename is a store-level no-op too.
        await store.renameConversation(id: row.id, title: "   ")
        let afterBlank = await store.get(id: row.id)?.title
        XCTAssertEqual(afterBlank, "After")
        // Same-title rename: no-op.
        await store.renameConversation(id: row.id, title: "After")
        let afterSame = await store.get(id: row.id)?.title
        XCTAssertEqual(afterSame, "After")
        // Unknown id: no-op, no crash.
        await store.renameConversation(id: UUID(), title: "Ghost")

        // Effect executor routes .updateTitle.
        _ = await store.apply(.updateTitle(conversationID: row.id, title: "Via Effect"))
        let afterEffect = await store.get(id: row.id)?.title
        XCTAssertEqual(afterEffect, "Via Effect")
    }

    // MARK: 6. Store write-through: pin / archive round-trips

    func testStorePinAndArchiveWriteThrough() async {
        let store = makeStore()
        let row = conv("Flagged")
        await store.upsert(row)

        await store.setPinned(true, conversationID: row.id)
        var fetched = await store.get(id: row.id)
        XCTAssertEqual(fetched?.pinned, true)
        var pinnedList = await store.conversationsPinned()
        XCTAssertEqual(pinnedList.map(\.id), [row.id], "pinned rows enter the Pinned section query")
        var page = await store.conversationsPage(offset: 0, limit: 20)
        XCTAssertFalse(page.rows.contains { $0.id == row.id },
                       "pinned rows leave Recents (Item 3 split preserved)")

        await store.setPinned(false, conversationID: row.id)
        fetched = await store.get(id: row.id)
        XCTAssertEqual(fetched?.pinned, false)
        pinnedList = await store.conversationsPinned()
        XCTAssertTrue(pinnedList.isEmpty)
        page = await store.conversationsPage(offset: 0, limit: 20)
        XCTAssertTrue(page.rows.contains { $0.id == row.id })

        await store.setArchived(true, conversationID: row.id)
        fetched = await store.get(id: row.id)
        XCTAssertEqual(fetched?.archived, true, "archive KEEPS the row (searchable, §8)")
        page = await store.conversationsPage(offset: 0, limit: 20)
        XCTAssertFalse(page.rows.contains { $0.id == row.id },
                       "archived rows leave Recents")
        pinnedList = await store.conversationsPinned()
        XCTAssertTrue(pinnedList.isEmpty, "archived rows leave Pinned too")
        let includingArchived = await store.conversationsIncludingArchived()
        XCTAssertTrue(includingArchived.contains { $0.id == row.id },
                      "archived rows stay visible to the search-facing query (Item 6)")

        // Effect executor routes .setPinned / .setArchived.
        _ = await store.apply(.setPinned(conversationID: row.id, pinned: true))
        _ = await store.apply(.setArchived(conversationID: row.id, archived: true))
        fetched = await store.get(id: row.id)
        XCTAssertEqual(fetched?.pinned, true)
        XCTAssertEqual(fetched?.archived, true)
    }

    // MARK: 7. Store write-through: delete (row + cascade)

    func testStoreDeleteRemovesRowAndMessages() async {
        let store = makeStore()
        let row = conv("Doomed")
        await store.upsert(row)
        await store.upsert(StoredMessage(
            conversationID: row.id, role: .user, content: "bye"))

        let deleted = await store.deleteConversation(id: row.id)
        XCTAssertTrue(deleted)
        let afterDelete = await store.get(id: row.id)
        XCTAssertNil(afterDelete)
        let messages = try? await store.messages(conversationID: row.id)
        XCTAssertEqual(messages?.count, 0, "messages cascade with the conversation row")
        // Deleting again reports false (idempotent contract).
        let again = await store.deleteConversation(id: row.id)
        XCTAssertFalse(again)
        // Effect executor routes .delete and .none.
        _ = await store.apply(.delete(conversationID: UUID()))
        _ = await store.apply(ListMechanicsEffect.none)
    }

    // MARK: 8. Auto-title hook through the store

    func testStoreAutoTitleHook() async {
        let store = makeStore()
        let row = conv("New chat")
        await store.upsert(row)

        // First user exchange → titles from the message text.
        let title1 = await store.applyAutoTitleIfFirstExchange(
            conversationID: row.id, messageRole: .user, messageText: "Krendora order status")
        XCTAssertEqual(title1, "Krendora order status")
        let afterTitle1 = await store.get(id: row.id)?.title
        XCTAssertEqual(afterTitle1, "Krendora order status")

        // Second user message → no further retitling.
        let title2 = await store.applyAutoTitleIfFirstExchange(
            conversationID: row.id, messageRole: .user, messageText: "Also check the budget")
        XCTAssertNil(title2)
        let afterTitle2 = await store.get(id: row.id)?.title
        XCTAssertEqual(afterTitle2, "Krendora order status")

        // Assistant message on a still-default row → no title.
        let other = conv("New chat")
        await store.upsert(other)
        let title3 = await store.applyAutoTitleIfFirstExchange(
            conversationID: other.id, messageRole: .assistant, messageText: "Hello!")
        XCTAssertNil(title3)
        let afterTitle3 = await store.get(id: other.id)?.title
        XCTAssertEqual(afterTitle3, "New chat")

        // Unknown conversation → nil, no crash.
        let title4 = await store.applyAutoTitleIfFirstExchange(
            conversationID: UUID(), messageRole: .user, messageText: "Ghost")
        XCTAssertNil(title4)
    }
}
