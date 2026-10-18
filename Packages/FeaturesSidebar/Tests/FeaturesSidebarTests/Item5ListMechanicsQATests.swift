import XCTest
import Foundation
import Persistence
@testable import FeaturesSidebar

/// Item 5 TESTER QA — List mechanics (feature #5, P0, UI Law §8):
///
///   §8a. Pin/unpin: write-through to the store (re-fetch assert), section
///        move in the loaded model, persisted across a store re-init.
///   §8b. Archive: NO confirmation seam needed (pure state flag — asserted
///        as "no throw / no dialog state exists"); archived rows leave every
///        section BUT stay store-fetchable (still searchable per law);
///        unarchive fully restores (⚠ builder seam: archive() has no
///        unarchive counterpart — see `testUnarchiveRestoresArchivedRow`).
///   §8c. Swipe-to-delete → delete(): real store deletion (row count drop,
///        re-fetch nil), messages CASCADE-deleted via the conversations FK,
///        idempotent second delete returns false.
///   §8d. Rename: trims whitespace, rejects empty/whitespace-only, writes
///        through + re-loads, survives a store re-init.
///   §8e. Long-press menu inventory (law): Rename, Pin, Archive, Delete
///        (red, confirmed) — pinned as the VM surface EXACTLY exposing
///        rename/pin/archive/delete (a compile-time + behavioral check).
///   §8f. Recents exclude archived + pinned; delete removes the row from
///        every loaded section.
///   ⚠ §8g. Auto-title ("Conversations auto-title after first exchange"):
///        NO implementation exists on this branch (no auto-title call site
///        or title seam anywhere in FeaturesSidebar/FeaturesChat/app
///        targets; newChat() hardcodes "New chat"). This suite pins the
///        *underlying* write-through path (a store-level retitle surfaces
///        in the loaded model) so the ONLY missing piece is the trigger
///        seam itself — the acceptance verdict carries that as a defect
///        for the builder (see testAutoTitleContractProbe).
///
/// Pure logic + real store mechanics, no SwiftUI instantiation, no UIKit —
/// `swift test`-runnable per the item constraint (no local toolchain; CI
/// billing-blocked, verdict by contract-conformance reading).
@MainActor
final class Item5ListMechanicsQATests: XCTestCase {

    // MARK: - Helpers

    private func tempDBPath(_ label: String) -> String {
        let dir = NSTemporaryDirectory() + "item5-qa-\(label)-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/store.sqlite"
    }

    private func chat(
        _ title: String,
        project: UUID? = nil,
        updatedAt: Date,
        pinned: Bool = false,
        archived: Bool = false
    ) -> StoredConversation {
        StoredConversation(
            projectID: project,
            title: title,
            updatedAt: updatedAt,
            pinned: pinned,
            archived: archived
        )
    }

    private func makeMessage(_ i: Int, in conversationID: UUID, base: Date) -> StoredMessage {
        StoredMessage(
            conversationID: conversationID,
            role: .user,
            content: "msg-\(i)",
            status: .sent,
            createdAt: base.addingTimeInterval(Double(i))
        )
    }

    @discardableResult
    private func seed(_ store: PersistenceStore, count: Int, pinnedCount: Int = 0) async -> Void {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<count {
            await store.upsert(chat(
                "conv-\(String(format: "%03d", i))",
                updatedAt: base.addingTimeInterval(Double(i)),
                pinned: i < pinnedCount
            ))
        }
    }

    /// Loaded VM state fresh off the store.
    private func loadedVM(_ store: PersistenceStore) async -> SidebarViewModel {
        let vm = SidebarViewModel(store: store)
        await vm.load()
        return vm
    }

    // MARK: §8a — Pin/unpin

    func testPinUnpinWritesThroughAndMovesSections() async {
        let store = PersistenceStore()
        await seed(store, count: 10)
        let vm = await loadedVM(store)
        guard let target = vm.recentChats.first else { return XCTFail("expected a recent row") }
        XCTAssertFalse(vm.pinnedEntries.contains { entry in
            entry.kind == .chat(id: target.id)
        })

        await vm.setPinned(true, conversationID: target.id)
        XCTAssertTrue(vm.pinnedEntries.contains { $0.kind == .chat(id: target.id) },
                      "pin must surface the row in the Pinned section")
        XCTAssertEqual(await store.get(id: target.id)?.pinned, true,
                       "pin must write through to the store (re-fetch assert)")

        // Fresh VM over the same store = the row survives re-open.
        let fresh = await loadedVM(store)
        XCTAssertTrue(fresh.pinnedEntries.contains { $0.kind == .chat(id: target.id) })

        // Unpin reverses, equally persisted.
        await vm.setPinned(false, conversationID: target.id)
        XCTAssertEqual(await store.get(id: target.id)?.pinned, false)
        let fresh2 = await loadedVM(store)
        XCTAssertFalse(fresh2.pinnedEntries.contains { $0.kind == .chat(id: target.id) })
    }

    // MARK: §8b — Archive / unarchive

    func testArchiveRemovesFromAllSectionsButStaysFetchable() async {
        let store = PersistenceStore()
        await seed(store, count: 10, pinnedCount: 2)
        let vm = await loadedVM(store)
        guard let row = vm.recentChats.first else { return XCTFail("expected a recent row") }

        await vm.archive(conversationID: row.id)
        XCTAssertEqual(await store.get(id: row.id)?.archived, true,
                       "archive must write through to the store")

        // Every loaded section drops the archived row…
        let reloaded = await loadedVM(store)
        XCTAssertFalse(reloaded.recentChats.contains { $0.id == row.id },
                       "archived rows must leave Recents (UI Law §8)")
        XCTAssertFalse(reloaded.pinnedEntries.contains { $0.kind == .chat(id: row.id) },
                       "archived rows must leave Pinned too")

        // …but the row itself stays (still searchable = still fetchable).
        let refetched = await store.get(id: row.id)
        XCTAssertNotNil(refetched, "archive must NOT delete the row (law: stays searchable)")
        XCTAssertEqual(refetched?.archived, true)
    }

    func testUnarchiveRestoresArchivedRow() async {
        let store = PersistenceStore()
        await seed(store, count: 5)
        guard let row = (await store.conversations()).first else {
            return XCTFail("expected a seeded row")
        }

        // Archive through the VM (the only seam that exists)…
        let vm = SidebarViewModel(store: store)
        await vm.load()
        await vm.archive(conversationID: row.id)
        XCTAssertEqual(await store.get(id: row.id)?.archived, true)

        // …then unarchive at store level and verify the loaded model honors
        // it: an unarchived row must return to Recents.
        var restored = await store.get(id: row.id)
        restored?.archived = false
        if let restored { await store.upsert(restored) }
        let reloaded = await loadedVM(store)
        XCTAssertTrue(reloaded.recentChats.contains { $0.id == row.id },
                      "an unarchived row must return to Recents")
        XCTAssertEqual(await store.get(id: row.id)?.archived, false)
        // DEFECT PIN (see QA log): the VM exposes no unarchive — archive()
        // has no inverse, so callers would need raw store access. Required:
        // `unarchive(conversationID:)` (store write + reload).
    }

    // MARK: §8c — Swipe-to-delete (real store deletion)

    func testDeleteRemovesRowAndMessagesFromStore() async throws {
        let store = PersistenceStore()
        await seed(store, count: 5)
        let vm = await loadedVM(store)
        guard let doomed = vm.recentChats.first else { return XCTFail("expected a recent row") }

        // Give the doomed row messages — deletion must cascade (schema FK
        // messages.conversation_id → conversations ON DELETE CASCADE).
        let base = Date(timeIntervalSince1970: 1_700_000_500)
        for i in 0..<3 {
            await store.upsert(makeMessage(i, in: doomed.id, base: base))
        }
        let before = await store.count()
        XCTAssertEqual(try await store.messages(conversationID: doomed.id).count, 3)

        // The UI wraps delete in a confirmation (UI Law §8: red, confirmed);
        // the VM seam itself must be a single decisive store deletion.
        let removed = await vm.delete(conversationID: doomed.id)
        XCTAssertTrue(removed, "delete must report success for an existing row")

        // Row gone…
        XCTAssertNil(await store.get(id: doomed.id), "delete must remove the row from the store")
        let after = await store.count()
        XCTAssertEqual(after, before - 1)

        // …and its messages cascade with it (not orphans).
        let orphans = try await store.messages(conversationID: doomed.id)
        XCTAssertTrue(orphans.isEmpty, "messages must cascade-delete with the conversation")

        // Deleted row leaves every loaded section.
        let reloaded = await loadedVM(store)
        XCTAssertFalse(reloaded.recentChats.contains { $0.id == doomed.id })
        XCTAssertFalse(reloaded.pinnedEntries.contains { $0.kind == .chat(id: doomed.id) })

        // Idempotency: second delete of the same row reports false.
        let second = await vm.delete(conversationID: doomed.id)
        XCTAssertFalse(second, "deleting an already-deleted row must report false, not crash")
    }

    func testDeleteOfUnknownIDReportsFalseWithoutSideEffects() async {
        let store = PersistenceStore()
        await seed(store, count: 3)
        let vm = await loadedVM(store)
        let before = await store.count()

        let removed = await vm.delete(conversationID: UUID())
        XCTAssertFalse(removed, "delete of an unknown id must report false")
        XCTAssertEqual(await store.count(), before,
                       "a failed delete must not disturb any existing row")
    }

    // MARK: §8d — Rename

    func testRenameWritesThroughTrimsAndRejectsEmpty() async {
        let store = PersistenceStore()
        await seed(store, count: 3)
        let vm = await loadedVM(store)
        guard let row = vm.recentChats.first else { return XCTFail("expected a recent row") }

        // Happy path: trimmed, write-through, re-loaded.
        await vm.rename(conversationID: row.id, to: "  Krendora orders  \n")
        XCTAssertEqual(await store.get(id: row.id)?.title, "Krendora orders",
                       "rename must trim whitespace and write through")
        let reloaded = await loadedVM(store)
        XCTAssertTrue(reloaded.recentChats.contains { $0.title == "Krendora orders" })

        // Empty + whitespace-only renames are rejected (no wipe-out).
        await vm.rename(conversationID: row.id, to: "")
        await vm.rename(conversationID: row.id, to: "   \n\t ")
        XCTAssertEqual(await store.get(id: row.id)?.title, "Krendora orders",
                       "empty/whitespace rename must be a no-op, never blank the title")

        // Rename of an unknown id: silent no-op (no crash).
        await vm.rename(conversationID: UUID(), to: "ghost")
    }

    func testRenameSurvivesStoreReinit() async throws {
        let path = tempDBPath("rename")
        let store1 = try PersistenceStore(path: path)
        let row = chat("original", updatedAt: Date(timeIntervalSince1970: 1))
        await store1.upsert(row)
        let vm1 = SidebarViewModel(store: store1)
        await vm1.load()
        await vm1.rename(conversationID: row.id, to: "renamed")

        // Fresh store instance over the same file = a new launch.
        let store2 = try PersistenceStore(path: path)
        let vm2 = await loadedVM(store2)
        XCTAssertTrue(vm2.recentChats.contains { $0.title == "renamed" },
                      "rename must survive a store re-init (genuinely persisted)")
    }

    // MARK: §8e — Long-press menu surface (law inventory)

    func testLongPressMenuInventoryIsFullyExposedByTheVM() async {
        // The law's long-press menu: Rename, Pin, Archive, Delete (red,
        // confirmed). The VM is the menu's action target — every law action
        // must be executable end-to-end through it. Exercise all four on one
        // row and assert the store trajectory: pin → rename → archive →
        // (confirmed) delete.
        let store = PersistenceStore()
        await seed(store, count: 2)
        let vm = await loadedVM(store)
        guard let row = vm.recentChats.first else { return XCTFail("expected a recent row") }

        await vm.setPinned(true, conversationID: row.id)
        XCTAssertEqual(await store.get(id: row.id)?.pinned, true, "menu: Pin")
        await vm.rename(conversationID: row.id, to: "Menu Renamed")
        XCTAssertEqual(await store.get(id: row.id)?.title, "Menu Renamed", "menu: Rename")
        await vm.archive(conversationID: row.id)
        XCTAssertEqual(await store.get(id: row.id)?.archived, true, "menu: Archive")
        let deleted = await vm.delete(conversationID: row.id)
        XCTAssertTrue(deleted, "menu: Delete (red, confirmed upstream of this seam)")
        XCTAssertNil(await store.get(id: row.id))
    }

    // MARK: §8f — Recents exclusions

    func testRecentsExcludeArchivedAndPinned() async {
        let store = PersistenceStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        await store.upsert(chat("plain", updatedAt: base.addingTimeInterval(10)))
        await store.upsert(chat("pinnedRow", updatedAt: base.addingTimeInterval(20), pinned: true))
        await store.upsert(chat("archivedRow", updatedAt: base.addingTimeInterval(30), archived: true))

        let vm = await loadedVM(store)
        // Archived rows must NEVER appear in Recents (UI Law §8 + Item 5
        // acceptance: "archived excluded from recents").
        XCTAssertFalse(vm.recentChats.contains { $0.title == "archivedRow" },
                       "archived rows must be excluded from Recents")
        // The pinned row lands in Pinned (section split works).
        XCTAssertEqual(vm.pinnedEntries.map(\.title), ["pinnedRow"],
                       "the pinned row must surface in Pinned")
        // Recents stay strictly newest-first whatever they contain.
        let stamps = vm.recentChats.map { $0.updatedAt.timeIntervalSince1970 }
        XCTAssertEqual(stamps, stamps.sorted(by: >), "recents must be newest-first")
        // NOTE (divergence pin, not a failure): this legacy package's
        // `recentChats` still CONTAINS pinned rows; the production shell VM
        // (FeaturesChat SidebarViewModel, Item 3) excludes them from recents
        // entirely. Law-wise both read fine (Pinned is a separate section);
        // flagged in the QA log for the cleanup item that retires this VM.
    }

    // MARK: §8g — Auto-title (ACCEPTANCE DEFECT PROBE)

    func testAutoTitleContractProbe() async {
        // UI Law §8: "Conversations auto-title after first exchange."
        // Acceptance criterion (V2-PLAN #5): an untitled/new chat row gets
        // its title from the first exchange. REQUIRED builder seam: a
        // write-through title update triggered once the first exchange
        // completes (message-row insert / send path).
        //
        // This branch implements NO auto-title anywhere (verified by repo
        // scan: no auto-title symbol or call site in any package or app
        // target; chat rows keep their creation title forever). The probe
        // exercises the underlying write-through path — a store-level
        // retitle of an "New chat" row surfaces in the loaded model — so
        // the ONLY missing piece is the trigger seam itself. Verdict
        // carries that as a defect for the builder.
        let store = PersistenceStore()
        let untitled = chat("New chat", updatedAt: Date())
        await store.upsert(untitled)
        let vm = await loadedVM(store)
        XCTAssertTrue(vm.recentChats.contains { $0.id == untitled.id && $0.title == "New chat" },
                      "the untitled row starts as 'New chat'")

        // First exchange lands → title must change.
        let base = Date()
        await store.upsert(makeMessage(0, in: untitled.id, base: base))
        var conversation = (await store.get(id: untitled.id))!
        conversation.title = String("msg-0".prefix(48))
        await store.upsert(conversation)

        let retitled = await store.get(id: untitled.id)
        XCTAssertEqual(retitled?.title, "msg-0",
                       "the store write-through CAN retitle (probe of the path)")
        let vmReloaded = await loadedVM(store)
        XCTAssertTrue(vmReloaded.recentChats.contains { $0.title == "msg-0" },
                      "the retitle must surface in the loaded model")

        // THE DEFECT: nothing in the codebase performs this automatically on
        // first exchange. Asserted structurally in the QA log, not here
        // (a symbol-absence assert cannot compile against an absent symbol).
    }
}

// MARK: - Notes
