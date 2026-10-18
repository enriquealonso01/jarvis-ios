import XCTest
import Persistence
import DesignSystem
import FeaturesChat

/// Item 3 TESTER QA — independent correctness verification for the
/// FeaturesChat `SidebarViewModel` (feature #2, UI Law §1/§8). These tests
/// hold the view model to its own advertised contract, independently of the
/// builder's suite:
///
///   1. Recents ordering: pinned rows live in `pinned` (newest first) and
///      never in `recents`; recents are strictly newest-first across pages.
///   2. Pin/unpin/archive persist through the store — re-fetch + re-load
///      asserts (the store is the source of truth, not shadow state).
///   3. Pagination boundary: 137 conversations → exact page arithmetic
///      (137 non-archived, page 1 = 20 newest, hasMore exactly tracks the
///      remainder, last page is the tail, past-end load is a no-op).
///   4. Search filter: client-side, case-insensitive over title + preview;
///      project tree narrows to matching chats; empty/whitespace query
///      resets to the unfiltered lists.
///   5. Project isolation: a conversation scoped to project A never appears
///      under project B (loaded tree AND newChat-append paths).
///   6. New chat: creates + selects + writes through the real store.
///   7. State restoration: open/closed + projectsExpanded + last selection
///      survive a store re-init (fresh store instance over the same file =
///      new launch); a dangling selection restores to nil.
///
/// No SwiftUI instantiation here — the app-target smoke suite covers views.
@MainActor
final class Item3SidebarCorrectnessQATests: XCTestCase {

    // MARK: - Helpers

    private func tempDBPath(_ label: String) -> String {
        let dir = NSTemporaryDirectory() + "item3-vm-qa-\(label)-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/store.sqlite"
    }

    private func chat(
        _ title: String,
        project: UUID? = nil,
        updatedAt: Date,
        pinned: Bool = false,
        archived: Bool = false,
        preview: String? = nil
    ) -> StoredConversation {
        var c = StoredConversation(
            projectID: project,
            title: title,
            updatedAt: updatedAt,
            pinned: pinned,
            archived: archived,
            lastMessagePreview: preview
        )
        c.updatedAt = updatedAt
        return c
    }

    /// 137 total conversations; staggered timestamps i → strictly older.
    /// Default: 2 pinned + 135 unpinned, 0 archived (caller can archive).
    @discardableResult
    private func seedConversations(
        _ store: PersistenceStore,
        count: Int,
        pinnedCount: Int = 0,
        archivedCount: Int = 0,
        projectID: UUID? = nil,
        base: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) async -> Int {
        var n = 0
        for i in 0..<count {
            let isPinned = i < pinnedCount
            let isArchived = i >= count - archivedCount
            let when = base.addingTimeInterval(Double(i))
            await store.upsert(chat(
                "conv-\(String(format: "%03d", i))",
                project: projectID,
                updatedAt: when,
                pinned: isPinned,
                archived: isArchived
            ))
            n += 1
        }
        return n
    }

    private let pageSize = Tokens.Sidebar.recentsPageSize

    // MARK: 1. Recents ordering — pinned separated, recents strictly newest-first

    func testPinnedRowsNeverAppearInRecentsAndOrderingIsNewestFirst() async {
        let store = PersistenceStore()
        await seedConversations(store, count: 30, pinnedCount: 5)
        let vm = SidebarViewModel(store: store)
        await vm.reload()

        XCTAssertEqual(vm.pinned.count, 5, "5 pinned rows must surface in the pinned section")
        XCTAssertFalse(vm.recents.contains { $0.pinned },
                       "a pinned row must never appear in recents")

        // Recents are paginated (Item 3 §2): page 1 = pageSize unpinned rows,
        // and walking every page yields exactly the 25 unpinned rows.
        XCTAssertEqual(vm.recents.count, min(25, pageSize), "page 1 is capped at the page size")
        XCTAssertTrue(vm.canLoadMoreRecents, "25 unpinned > 20 → more pages exist")
        var all = vm.recents
        while vm.canLoadMoreRecents {
            await vm.loadMoreRecents()
            all = vm.recents
        }
        XCTAssertEqual(all.count, 25, "all unpinned rows must come through the pages")
        XCTAssertFalse(all.contains { $0.pinned }, "no pinned row across any page")

        // Strict newest-first within recents.
        let stamps = all.map { $0.updatedAt.timeIntervalSince1970 }
        XCTAssertEqual(stamps, stamps.sorted(by: >), "recents must be strictly newest-first")

        // Pinned section newest-first too.
        let pinnedStamps = vm.pinned.map { $0.updatedAt.timeIntervalSince1970 }
        XCTAssertEqual(pinnedStamps, pinnedStamps.sorted(by: >))
    }

    // MARK: 2. Pin/unpin/archive persist through the store (re-fetch asserts)

    func testPinUnpinPersistsThroughStoreRefetch() async {
        let store = PersistenceStore()
        await seedConversations(store, count: 10)
        let vm = SidebarViewModel(store: store)
        await vm.reload()
        guard let target = vm.recents.first else { return XCTFail("expected a recent row") }

        // Pin → in-memory section move AND store write-through.
        await vm.setPinned(true, conversationID: target.id)
        XCTAssertTrue(vm.pinned.contains { $0.id == target.id })
        XCTAssertFalse(vm.recents.contains { $0.id == target.id })
        XCTAssertEqual(await store.get(id: target.id)?.pinned, true,
                       "pin must write through to the store (re-fetch assert)")

        // A fresh VM (simulating re-open) must see the pinned row.
        let fresh = SidebarViewModel(store: store)
        await fresh.reload()
        XCTAssertTrue(fresh.pinned.contains { $0.id == target.id })
        XCTAssertFalse(fresh.recents.contains { $0.id == target.id })

        // Unpin → reverse, equally persisted.
        await vm.setPinned(false, conversationID: target.id)
        XCTAssertEqual(await store.get(id: target.id)?.pinned, false,
                       "unpin must write through to the store")
        let fresh2 = SidebarViewModel(store: store)
        await fresh2.reload()
        XCTAssertFalse(fresh2.pinned.contains { $0.id == target.id })
        XCTAssertTrue(fresh2.recents.contains { $0.id == target.id })
    }

    func testArchivePersistsAndRemovesFromAllSections() async {
        let store = PersistenceStore()
        await seedConversations(store, count: 10, pinnedCount: 2)
        let vm = SidebarViewModel(store: store)
        await vm.reload()

        // Archive an unpinned row.
        guard let unpinned = vm.recents.first else { return XCTFail("expected a recent row") }
        await vm.setArchived(true, conversationID: unpinned.id)
        XCTAssertEqual(await store.get(id: unpinned.id)?.archived, true,
                       "archive must write through to the store (re-fetch assert)")
        XCTAssertFalse(vm.recents.contains { $0.id == unpinned.id })
        XCTAssertFalse(vm.pinned.contains { $0.id == unpinned.id })
        // Archived row is gone from the store's page query too.
        let page = await store.conversationsPage(offset: 0, limit: 100)
        XCTAssertFalse(page.rows.contains { $0.id == unpinned.id },
                       "archived rows must not come back on the next page fetch")

        // Archive a PINNED row: must leave both sections (UI Law §8 keeps it
        // searchable, not listed).
        guard let pinnedRow = vm.pinned.first else { return XCTFail("expected a pinned row") }
        await vm.setArchived(true, conversationID: pinnedRow.id)
        XCTAssertFalse(vm.pinned.contains { $0.id == pinnedRow.id },
                       "archiving a pinned row must remove it from Pinned")
        XCTAssertFalse(vm.recents.contains { $0.id == pinnedRow.id })
        let reloaded = SidebarViewModel(store: store)
        await reloaded.reload()
        XCTAssertTrue(reloaded.pinned.isEmpty, "pinned section must be empty after archiving the only pinned row")

        // Unarchive restores it to recents (still searchable → still fetchable).
        await vm.setArchived(false, conversationID: unpinned.id)
        XCTAssertEqual(await store.get(id: unpinned.id)?.archived, false)
    }

    // MARK: 3. Pagination boundary — 137 conversations

    func testPaginationBoundary137ConversationsPagesCorrectly() async {
        let store = PersistenceStore()
        await seedConversations(store, count: 137)
        let vm = SidebarViewModel(store: store)
        await vm.reload()

        // 137 conversations, page size 20 → 6 full pages + 17-row tail.
        XCTAssertEqual(vm.recents.count, pageSize, "page 1 must be exactly the page size")
        XCTAssertTrue(vm.canLoadMoreRecents, "137 > 20 → more pages must exist")
        XCTAssertEqual(vm.recents.first?.title, "conv-136", "page 1 leads with the newest")

        var loaded = vm.recents.count
        var pages = 1
        var seen = Set(vm.recents.map { $0.id })
        while vm.canLoadMoreRecents {
            await vm.loadMoreRecents()
            pages += 1
            let fresh = vm.recents.suffix(from: loaded)
            XCTAssertEqual(fresh.count, min(pageSize, 137 - loaded),
                           "page \(pages) must carry exactly the remaining rows (no dup/gap)")
            for row in fresh { XCTAssertFalse(seen.contains(row.id), "duplicate row across pages") }
            for row in fresh { seen.insert(row.id) }
            loaded = vm.recents.count
        }
        XCTAssertEqual(loaded, 137, "all 137 conversations must come through the pages")
        XCTAssertEqual(pages, 7, "137 rows / 20 per page → exactly 7 pages")
        XCTAssertFalse(vm.canLoadMoreRecents, "hasMore must be false after the tail page")

        // Past-end load is an idempotent no-op.
        await vm.loadMoreRecents()
        XCTAssertEqual(vm.recents.count, 137, "loading past the end must not duplicate or error")
    }

    func testPaginationBoundaryExcludesArchivedFromTheArithmetic() async {
        let store = PersistenceStore()
        await seedConversations(store, count: 137, archivedCount: 7)
        let vm = SidebarViewModel(store: store)
        await vm.reload()
        XCTAssertFalse(vm.recents.contains { $0.archived })
        // 130 visible → 6 full pages + 10-row tail.
        var loaded = vm.recents.count
        while vm.canLoadMoreRecents {
            await vm.loadMoreRecents()
            loaded = vm.recents.count
        }
        XCTAssertEqual(loaded, 130, "archived rows must be excluded from pagination entirely")
    }

    // MARK: 4. Search filter — client-side, case-insensitive, empty reset

    func testSearchFilterCaseInsensitiveOverTitleAndPreview() async {
        let store = PersistenceStore()
        await store.upsert(chat("Krendora orders", updatedAt: Date(timeIntervalSince1970: 10)))
        await store.upsert(chat("home budget", updatedAt: Date(timeIntervalSince1970: 20)))
        await store.upsert(chat(
            "Untitled", updatedAt: Date(timeIntervalSince1970: 30),
            preview: "call the CONTRACTOR about tiles"
        ))
        let vm = SidebarViewModel(store: store)
        await vm.reload()

        vm.searchQuery = "KREN"
        XCTAssertEqual(vm.filteredRecents.map { $0.title }, ["Krendora orders"],
                       "filter must be case-insensitive")

        vm.searchQuery = "contractor"
        XCTAssertEqual(vm.filteredRecents.map { $0.title }, ["Untitled"],
                       "preview must match even when the title does not")

        vm.searchQuery = "budget"
        XCTAssertEqual(vm.filteredRecents.map { $0.title }, ["home budget"])

        vm.searchQuery = "zzz-no-match"
        XCTAssertTrue(vm.filteredRecents.isEmpty, "no match → empty filtered list")
        // The unfiltered source must remain intact (filter is client-side).
        XCTAssertEqual(vm.recents.count, 3)
    }

    func testSearchFilterCoversProjectTreeWithoutCrossProjectLeaks() async {
        let projectA = StoredProject(name: "Alpha")
        let projectB = StoredProject(name: "Beta")
        let store = PersistenceStore()
        await store.upsert(projectA)
        await store.upsert(projectB)
        await store.upsert(chat("alpha thing", project: projectA.id, updatedAt: Date(timeIntervalSince1970: 1)))
        await store.upsert(chat("filler", project: projectB.id, updatedAt: Date(timeIntervalSince1970: 2)))
        let vm = SidebarViewModel(store: store)
        await vm.reload()

        vm.searchQuery = "alpha"
        XCTAssertEqual(vm.filteredProjects.count, 1)
        XCTAssertEqual(vm.filteredProjects.first?.project.id, projectA.id,
                       "only the matching project node stays")
        XCTAssertEqual(vm.filteredProjects.first?.conversations.map { $0.title }, ["alpha thing"])

        // Whitespace-only query behaves like empty (reset).
        vm.searchQuery = "   "
        XCTAssertEqual(vm.filteredRecents.count, vm.recents.count)
        XCTAssertEqual(vm.filteredProjects.count, vm.projects.count)

        // Empty query resets the filter to the unfiltered lists.
        vm.searchQuery = ""
        XCTAssertEqual(vm.filteredRecents.count, vm.recents.count)
        XCTAssertEqual(vm.filteredProjects.count, vm.projects.count)
        XCTAssertEqual(vm.filteredRecents.map { $0.title }.sorted(),
                       vm.recents.map { $0.title }.sorted())
    }

    // MARK: 5. Project isolation — a chat in project A never appears under B

    func testProjectIsolationConversationInANeverAppearsUnderB() async {
        let projectA = StoredProject(name: "A")
        let projectB = StoredProject(name: "B")
        let store = PersistenceStore()
        await store.upsert(projectA)
        await store.upsert(projectB)
        let inA = chat("belongs-to-A", project: projectA.id, updatedAt: Date(timeIntervalSince1970: 1))
        let inB = chat("belongs-to-B", project: projectB.id, updatedAt: Date(timeIntervalSince1970: 2))
        let loose = chat("loose", updatedAt: Date(timeIntervalSince1970: 3))
        await store.upsert(inA)
        await store.upsert(inB)
        await store.upsert(loose)

        let vm = SidebarViewModel(store: store)
        await vm.reload()

        let nodeA = vm.projects.first { $0.project.id == projectA.id }
        let nodeB = vm.projects.first { $0.project.id == projectB.id }
        XCTAssertEqual(nodeA?.conversations.map { $0.id }, [inA.id])
        XCTAssertEqual(nodeB?.conversations.map { $0.id }, [inB.id])
        XCTAssertFalse(nodeB?.conversations.contains { $0.id == inA.id } ?? true,
                       "conversation in project A must NEVER appear under project B")
        XCTAssertFalse(nodeA?.conversations.contains { $0.id == inB.id } ?? true)
        XCTAssertFalse(vm.projects.contains { node in
            node.project.id != projectA.id && node.conversations.contains { $0.id == inA.id }
        }, "no other node may carry a project-A conversation")

        // Isolation holds across a pin mutation (apply() path mirrors rows
        // into nodes — a bug there could leak it across projects).
        await vm.setPinned(true, conversationID: inA.id)
        XCTAssertFalse(vm.projects.contains { node in
            node.project.id != projectA.id && node.conversations.contains { $0.id == inA.id }
        }, "pin must not leak the row into another project's node")

        // And across newChat (append path).
        let created = await vm.newChat(projectID: projectA.id, title: "fresh in A")
        let aAfter = vm.projects.first { $0.project.id == projectA.id }
        let bAfter = vm.projects.first { $0.project.id == projectB.id }
        XCTAssertTrue(aAfter?.conversations.contains { $0.id == created.id } ?? false)
        XCTAssertFalse(bAfter?.conversations.contains { $0.id == created.id } ?? true,
                       "newChat into A must never land under B")
    }

    // MARK: 6. New chat creates a row

    func testNewChatCreatesStoreRowAndLeadsRecents() async {
        let store = PersistenceStore()
        await seedConversations(store, count: 5)
        let vm = SidebarViewModel(store: store)
        await vm.reload()

        let created = await vm.newChat()
        XCTAssertEqual(vm.selectedConversationID, created.id, "new chat must select itself")
        XCTAssertEqual(vm.recents.first?.id, created.id, "new chat must lead recents")
        let persisted = await store.get(id: created.id)
        XCTAssertEqual(persisted?.title, "New chat", "row must exist in the real store")

        // Reload from store: the row is still there (not just in-memory).
        let fresh = SidebarViewModel(store: store)
        await fresh.reload()
        XCTAssertTrue(fresh.recents.contains { $0.id == created.id })
    }

    // MARK: 7. State restoration survives a full store re-init (file-backed)

    func testOpenClosedAndLastSelectionSurviveStoreReinit() async throws {
        let path = tempDBPath("restore")
        let store1 = try PersistenceStore(path: path)
        let keep = chat("keeper", updatedAt: Date(timeIntervalSince1970: 1))
        await store1.upsert(keep)

        // Session 1: open sidebar, collapse projects, select a conversation.
        let vm1 = SidebarViewModel(store: store1)
        await vm1.setOpen(true)
        await vm1.setProjectsExpanded(false)
        await vm1.select(conversationID: keep.id)

        // Session 2: brand-new store instance over the SAME file (the
        // cold-launch re-init) + brand-new VM.
        let store2 = try PersistenceStore(path: path)
        let vm2 = SidebarViewModel(store: store2)
        await vm2.restoreState()
        XCTAssertTrue(vm2.isOpen, "open/closed must survive the store re-init")
        XCTAssertFalse(vm2.projectsExpanded, "projects collapse must survive the re-init")
        XCTAssertEqual(vm2.selectedConversationID, keep.id, "last selection must survive the re-init")

        // Toggling closed persists too.
        await vm2.setOpen(false)
        let store3 = try PersistenceStore(path: path)
        let vm3 = SidebarViewModel(store: store3)
        await vm3.restoreState()
        XCTAssertFalse(vm3.isOpen, "closed state must equally survive the re-init")
        XCTAssertEqual(vm3.selectedConversationID, keep.id)
    }

    func testDanglingSelectionRestoresToNilAfterRowDeletion() async throws {
        let path = tempDBPath("dangling")
        let store1 = try PersistenceStore(path: path)
        let doomed = chat("doomed", updatedAt: Date(timeIntervalSince1970: 1))
        await store1.upsert(doomed)
        let vm1 = SidebarViewModel(store: store1)
        await vm1.select(conversationID: doomed.id)

        // Delete the row, then re-init.
        await store1.deleteConversation(id: doomed.id)
        let store2 = try PersistenceStore(path: path)
        let vm2 = SidebarViewModel(store: store2)
        await vm2.restoreState()
        XCTAssertNil(vm2.selectedConversationID,
                     "a selection whose row no longer exists must NOT restore")
    }

    func testRestoreKeepsDefaultsWhenNothingWasPersisted() async {
        let store = PersistenceStore()
        let vm = SidebarViewModel(store: store)
        await vm.restoreState()
        XCTAssertFalse(vm.isOpen, "fresh install → closed")
        XCTAssertTrue(vm.projectsExpanded, "fresh install → default expanded")
        XCTAssertNil(vm.selectedConversationID, "fresh install → no selection")
    }
}
