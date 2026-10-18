import XCTest
import Persistence
import FeaturesChat

// MARK: - Item 5 BUILDER tests: composer → auto-title feed + unarchive
// (feature #5, UI Law §8). Pure logic, real store, no UIKit.
@MainActor
final class Item5AutoTitleFeedTests: XCTestCase {

    // MARK: 1. Composer send feed (the auto-title trigger facts)

    func testSendPublishesAutoTitleFeedFacts() async throws {
        let store = PersistenceStore()
        let vm = ComposerViewModel(store: store)
        XCTAssertEqual(vm.sentMessageCount, 0, "no sends → no feed ticks")
        XCTAssertNil(vm.lastSentRole)
        XCTAssertNil(vm.lastSentText)

        vm.text = "Plan my week"
        let ok = try await vm.send()
        XCTAssertTrue(ok)
        XCTAssertEqual(vm.sentMessageCount, 1, "one successful send = one tick")
        XCTAssertEqual(vm.lastSentRole, MessageRole.user)
        XCTAssertEqual(vm.lastSentText, "Plan my week")

        // Whitespace-only send is a guarded no-op → no feed tick.
        vm.text = "   "
        let second = try await vm.send()
        XCTAssertFalse(second)
        XCTAssertEqual(vm.sentMessageCount, 1, "failed send must not tick the feed")

        vm.text = "Second thought"
        _ = try await vm.send()
        XCTAssertEqual(vm.sentMessageCount, 2, "monotonic counter")
        XCTAssertEqual(vm.lastSentText, "Second thought")
    }

    // MARK: 2. End-to-end: send → shell hook → conversation retitled

    func testComposerSendFeedsFirstExchangeAutoTitle() async throws {
        let store = PersistenceStore()
        let sidebar = SidebarViewModel(store: store)
        let conversation = await sidebar.newChat(title: "New chat")
        XCTAssertEqual(await store.get(id: conversation.id)?.title, "New chat")

        // The composer send (local-first user row) + the shell's
        // onChange hook, replayed exactly as V2ComposerHost wires them.
        let composer = ComposerViewModel(store: store)
        composer.conversationID = conversation.id
        composer.text = "Check the Krendora order queue"
        _ = try await composer.send()
        _ = await sidebar.applyAutoTitleIfFirstExchange(
            conversationID: conversation.id,
            messageRole: composer.lastSentRole ?? .user,
            messageText: composer.lastSentText ?? "")

        XCTAssertEqual(await store.get(id: conversation.id)?.title,
                       "Check the Krendora order queue",
                       "first user exchange must retitle the conversation")
        // The sidebar model surfaces the new title after reload.
        await sidebar.reload()
        XCTAssertTrue(sidebar.recents.contains { $0.id == conversation.id && $0.title == "Check the Krendora order queue" })
    }

    // MARK: 3. Unarchive (QA defect #2 seam)

    func testUnarchiveRestoresRowToRecents() async {
        let store = PersistenceStore()
        let vm = SidebarViewModel(store: store)
        let row = StoredConversation(
            title: "Archived", updatedAt: Date(timeIntervalSince1970: 100), archived: true)
        await store.upsert(row)
        await vm.reload()
        XCTAssertFalse(vm.recents.contains { $0.id == row.id })

        await vm.unarchive(conversationID: row.id)
        XCTAssertEqual(await store.get(id: row.id)?.archived, false,
                       "unarchive writes through (defect #2 seam)")
        XCTAssertTrue(vm.recents.contains { $0.id == row.id },
                      "unarchived row returns to Recents")
        // Unknown id: silent no-op.
        await vm.unarchive(conversationID: UUID())
    }
}
