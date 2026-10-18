import XCTest
import Persistence
import FeaturesChat

// MARK: - Item 5 BUILDER tests: list mechanics through the sidebar view
// model (feature #5, UI Law §8) — store-backed, no UIKit, mirrors the
// Item 3 SidebarViewModel QA pattern.
@MainActor
final class Item5SidebarListMechanicsTests: XCTestCase {

    // MARK: Helpers

    private func makeStore() -> PersistenceStore { PersistenceStore() }

    private func chat(
        _ title: String,
        updatedAt: Date = Date(timeIntervalSince1970: 100),
        pinned: Bool = false,
        archived: Bool = false
    ) -> StoredConversation {
        var c = StoredConversation(title: title, updatedAt: updatedAt)
        c.pinned = pinned
        c.archived = archived
        return c
    }

    // MARK: 1. Rename through the VM

    func testRenameWritesThroughAndReloads() async {
        let store = makeStore()
        let vm = SidebarViewModel(store: store)
        let row = chat("New chat")
        await store.upsert(row)
        await vm.reload()

        let changed = await vm.rename(conversationID: row.id, to: "Trip plans")
        XCTAssertTrue(changed)
        let hoisted1 = await store.get(id: row.id)?.title
        XCTAssertEqual(hoisted1, "Trip plans", "rename must write through")
        let fresh = SidebarViewModel(store: store)
        await fresh.reload()
        XCTAssertTrue(fresh.recents.contains { $0.title == "Trip plans" },
                      "reload must surface the new title")
    }

    func testRenameGatesAreNoOps() async {
        let store = makeStore()
        let vm = SidebarViewModel(store: store)
        let row = chat("Keep")
        await store.upsert(row)

        // Blank/whitespace-only names never land.
        let hoisted2 = await vm.rename(conversationID: row.id, to: "")
        XCTAssertFalse(hoisted2)
        let hoisted3 = await vm.rename(conversationID: row.id, to: "   \n ")
        XCTAssertFalse(hoisted3)
        let hoisted4 = await store.get(id: row.id)?.title
        XCTAssertEqual(hoisted4, "Keep")
        // No-change rename: false, no write.
        let hoisted5 = await vm.rename(conversationID: row.id, to: "Keep")
        XCTAssertFalse(hoisted5)
        // Unknown id: false, no crash.
        let hoisted6 = await vm.rename(conversationID: UUID(), to: "Ghost")
        XCTAssertFalse(hoisted6)
    }

    // MARK: 2. Delete + swipe-delete through the VM

    func testSwipeDeleteRemovesRowAndCleansSelection() async {
        let store = makeStore()
        let vm = SidebarViewModel(store: store)
        let a = chat("A", updatedAt: Date(timeIntervalSince1970: 200))
        let doomed = chat("Doomed", updatedAt: Date(timeIntervalSince1970: 100))
        await store.upsert(a)
        await store.upsert(doomed)
        await vm.select(conversationID: doomed.id)
        XCTAssertEqual(vm.selectedConversationID, doomed.id)

        // Swipe left → delete, confirmed UI-side; the VM path runs it.
        await vm.swipeDelete(conversationID: doomed.id)

        let hoisted7 = await store.get(id: doomed.id)
        XCTAssertNil(hoisted7, "swipe delete removes the row")
        XCTAssertNil(vm.selectedConversationID,
                     "a deleted selected row must drop the selection")
        // The restore key is cleaned so a cold launch can't restore a ghost.
        let restoredID: String? = await store.appState(String.self, key: "v2.sidebar.last-selection")
        XCTAssertNil(restoredID, "selection restore key must be removed on delete")
        // And it reloads: the row left Recents.
        let fresh = SidebarViewModel(store: store)
        await fresh.reload()
        XCTAssertFalse(fresh.recents.contains { $0.id == doomed.id })
        XCTAssertTrue(fresh.recents.contains { $0.id == a.id })
    }

    func testDeleteKeepsOtherRowsAndSurvivesReinit() async throws {
        let path = NSTemporaryDirectory() + "item5-delete-\(UUID().uuidString).sqlite"
        let store = try PersistenceStore(path: path)
        let vm = SidebarViewModel(store: store)
        let keep = chat("Keep", updatedAt: Date(timeIntervalSince1970: 300))
        let doomed = chat("Doomed", updatedAt: Date(timeIntervalSince1970: 200))
        await store.upsert(keep)
        await store.upsert(doomed)
        await vm.select(conversationID: doomed.id)

        await vm.delete(conversationID: doomed.id)

        // Menu delete (confirmed) has the same semantics as swipe delete.
        let hoisted8 = await store.get(id: doomed.id)
        XCTAssertNil(hoisted8)
        XCTAssertEqual(vm.selectedConversationID, nil)

        // File-backed re-init: the deletion is durable, selection stays nil.
        let store2 = try PersistenceStore(path: path)
        let vm2 = SidebarViewModel(store: store2)
        await vm2.restoreState()
        XCTAssertNil(vm2.selectedConversationID,
                     "deleted row must not restore as the last selection")
        await vm2.reload()
        XCTAssertTrue(vm2.recents.contains { $0.id == keep.id })
    }

    func testDeleteOnlyTouchesTargetRow() async {
        let store = makeStore()
        let vm = SidebarViewModel(store: store)
        let a = chat("A", updatedAt: Date(timeIntervalSince1970: 300))
        let b = chat("B", updatedAt: Date(timeIntervalSince1970: 200))
        await store.upsert(a)
        await store.upsert(b)
        await vm.select(conversationID: a.id)

        await vm.delete(conversationID: b.id)
        let hoisted9 = await store.get(id: a.id)
        XCTAssertNotNil(hoisted9, "deleting B must not touch A")
        XCTAssertEqual(vm.selectedConversationID, a.id, "A's selection survives")
    }

    // MARK: 3. Auto-title through the VM (first-exchange hook)

    func testAutoTitleThroughVMFirstExchangeOnly() async {
        let store = makeStore()
        let vm = SidebarViewModel(store: store)
        let row = chat("New chat")
        await store.upsert(row)
        await vm.reload()

        let t1 = await vm.applyAutoTitleIfFirstExchange(
            conversationID: row.id, messageRole: .user,
            messageText: "What is the Krendora order status today")
        XCTAssertEqual(t1, "What is the Krendora order status today")
        let hoisted10 = await store.get(id: row.id)?.title
        XCTAssertEqual(hoisted10, t1)

        let t2 = await vm.applyAutoTitleIfFirstExchange(
            conversationID: row.id, messageRole: .user, messageText: "Second message")
        XCTAssertNil(t2, "only the FIRST exchange titles the row")
    }

    func testAutoTitleSkipsRenamedRows() async {
        let store = makeStore()
        let vm = SidebarViewModel(store: store)
        let row = chat("My custom name")
        await store.upsert(row)

        let t = await vm.applyAutoTitleIfFirstExchange(
            conversationID: row.id, messageRole: .user, messageText: "hello there")
        XCTAssertNil(t, "rename wins permanently — auto-title must not override")
        let hoisted11 = await store.get(id: row.id)?.title
        XCTAssertEqual(hoisted11, "My custom name")
    }

    // MARK: 4. Archive through the VM (regression: §8 semantics on the
    // Item 3 mutator — no confirmation, row kept, sections updated)

    func testArchiveKeepsRowButClearsSectionsAndSelection() async {
        let store = makeStore()
        let vm = SidebarViewModel(store: store)
        let row = chat("Archive me")
        await store.upsert(row)
        await vm.select(conversationID: row.id)

        await vm.setArchived(true, conversationID: row.id)

        let fetched = await store.get(id: row.id)
        XCTAssertEqual(fetched?.archived, true, "archive keeps the row (searchable)")
        XCTAssertEqual(fetched?.pinned, false)
        let includingArchived = await store.conversationsIncludingArchived()
        XCTAssertTrue(includingArchived.contains { $0.id == row.id },
                      "archived stays in the search-facing row set (Item 6)")
        // Item 3's dangling-selection rule already cleared it; assert anyway.
        XCTAssertNil(vm.selectedConversationID)
        await vm.reload()
        XCTAssertFalse(vm.recents.contains { $0.id == row.id })
    }

    // MARK: 5. Pin through the VM (§8 via long-press) — reuses the Item 3
    // write-through; regression-pins the Recents↔Pinned move.

    func testPinMovesRowBetweenSections() async {
        let store = makeStore()
        let vm = SidebarViewModel(store: store)
        let row = chat("Pin me", updatedAt: Date(timeIntervalSince1970: 100))
        await store.upsert(row)
        await vm.reload()
        XCTAssertTrue(vm.recents.contains { $0.id == row.id })

        await vm.setPinned(true, conversationID: row.id)
        XCTAssertTrue(vm.pinned.contains { $0.id == row.id })
        XCTAssertFalse(vm.recents.contains { $0.id == row.id })

        await vm.setPinned(false, conversationID: row.id)
        XCTAssertFalse(vm.pinned.contains { $0.id == row.id })
        XCTAssertTrue(vm.recents.contains { $0.id == row.id })
    }
}
