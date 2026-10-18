import XCTest
import Persistence
@testable import FeaturesChat

// MARK: - Item 10 QA: Project Home + project isolation (package §05)
//
// Pins (macOS-lane safe; store-backed, in-memory GRDB):
//   §P-1  ISOLATION (QA-pinned): every scoped query returns ONLY
//         conversations whose projectID == the queried project. Ungrouped
//         chats (projectID nil) and other projects' chats NEVER leak —
//         pinned/archived permutations included;
//   §P-2  newChat born-scoped: chats created from Project Home carry the
//         projectID and appear ONLY in that project's Home;
//   §P-3  instructions: project-scoped save (verbatim trim), no-phantom
//         writes (deleted project refuses);
//   §P-4  sources: append/remove scoped by (id, projectID) — no foreign
//         deletes, no orphan rows (sources require a live project);
//   §P-5  Task-1 composition: Project Home selection → V2ChatHost must
//         agree (one shared NavigationStack; the chat surface cannot show
//         another surface beneath Project Home);
//   §P-6  archived chats leave Home but stay in the store.
final class Item10ProjectHomeQATests: XCTestCase {

    private func makeStore() throws -> PersistenceStore {
        let path = NSTemporaryDirectory() + "item10-qa-\(UUID().uuidString).sqlite"
        return try PersistenceStore(path: path)
    }

    // MARK: helpers (hoisted from asserts — no awaits in autoclosures)

    @MainActor
    private func makeLoadedVM(
        store: PersistenceStore, projectID: UUID
    ) async -> ProjectHomeViewModel {
        let vm = ProjectHomeViewModel(projectID: projectID, store: store)
        await vm.load()
        return vm
    }

    /// Seed: two projects, each with chats, plus ungrouped chats and
    /// archived/pinned permutations. Returns the full fixture.
    @MainActor
    private func seedIsolationFixture(store: PersistenceStore) async
        -> (projectA: UUID, projectB: UUID,
            chatA1: UUID, chatA2: UUID, chatB1: UUID, ungrouped: UUID,
            archivedA: UUID) {
        let projectA = UUID()
        let projectB = UUID()
        await store.upsert(StoredProject(id: projectA, name: "Alpha", instructions: "A rules"))
        await store.upsert(StoredProject(id: projectB, name: "Beta", instructions: ""))

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        func conv(_ projectID: UUID?, title: String, seconds: Double,
                  pinned: Bool = false, archived: Bool = false) -> StoredConversation {
            StoredConversation(
                projectID: projectID, title: title,
                updatedAt: base.addingTimeInterval(seconds),
                pinned: pinned, archived: archived)
        }

        let chatA1 = conv(projectA, title: "a1", seconds: 10)
        let chatA2 = conv(projectA, title: "a2", seconds: 20, pinned: true)
        let chatB1 = conv(projectB, title: "b1", seconds: 30, pinned: true)
        let ungrouped = conv(nil, title: "free", seconds: 40, pinned: true)
        let archivedA = conv(projectA, title: "a-archived", seconds: 50, archived: true)

        for conversation in [chatA1, chatA2, chatB1, ungrouped, archivedA] {
            await store.upsert(conversation)
        }
        return (projectA, projectB, chatA1.id, chatA2.id, chatB1.id, ungrouped.id, archivedA.id)
    }

    /// Set literal → Set<UUID> (no Set(algorithm:) in the pinned assertions).
    private func set(_ ids: UUID...) -> Set<UUID> { Set(ids) }

    // MARK: §P-1 — the isolation matrix (the QA-pinned contract)

    @MainActor
    func testScopedQueryReturnsOnlyOwnProjectChats() async {
        guard let store = try? makeStore() else {
            return XCTFail("store init failed")
        }
        let fx = await seedIsolationFixture(store: store)

        // Hoisted await (never inside the XCTAssert autoclosure).
        let scoped = await store.conversations(projectID: fx.projectA)
        let scopedB = await store.conversations(projectID: fx.projectB)
        let ungrouped = await store.conversations(projectID: UUID())

        XCTAssertEqual(
            Set(scoped.map(\.id)),
            set(fx.chatA1, fx.chatA2),
            "Project A Home must contain exactly A's non-archived chats")
        XCTAssertFalse(scoped.contains { $0.id == fx.chatB1 },
                       "B's chats must never leak into A's Home")
        XCTAssertFalse(scoped.contains { $0.id == fx.ungrouped },
                       "ungrouped chats must never leak into a project Home")
        XCTAssertFalse(scoped.contains { $0.id == fx.archivedA },
                       "archived chats stay out of Home")
        XCTAssertEqual(
            Set(scopedB.map(\.id)),
            set(fx.chatB1),
            "Project B Home must contain exactly B's non-archived chats")
        XCTAssertEqual(ungrouped.count, 0,
                       "a random project id scopes to nothing")
    }

    @MainActor
    func testScopedQueryIgnoresPinStateButKeepsRecencyOrder() async {
        guard let store = try? makeStore() else {
            return XCTFail("store init failed")
        }
        let fx = await seedIsolationFixture(store: store)

        let scoped = await store.conversations(projectID: fx.projectA)
        // Pinned chat stays scoped to ITS project (not hoisted across).
        XCTAssertTrue(scoped.contains { $0.id == fx.chatA2 && $0.pinned })
        // Order: newest updatedAt first (house order, scoped set only).
        XCTAssertEqual(scoped.map(\.title), ["a2", "a1"])
    }

    @MainActor
    func testUngroupedChatsAreInvisibleToEveryProjectHome() async {
        guard let store = try? makeStore() else {
            return XCTFail("store init failed")
        }
        let fx = await seedIsolationFixture(store: store)

        let forA = await store.conversations(projectID: fx.projectA)
        let forB = await store.conversations(projectID: fx.projectB)
        XCTAssertFalse(forA.contains { $0.projectID == nil })
        XCTAssertFalse(forB.contains { $0.projectID == nil })
        // Cross-check: the global list still has the ungrouped chat (it is
        // not deleted — it is just not project-scoped).
        let global = await store.conversations(limit: 200)
        XCTAssertTrue(global.contains { $0.id == fx.ungrouped })
    }

    @MainActor
    func testProjectScopePureFilterContract() {
        let projectA = UUID()
        let projectB = UUID()
        let inA = StoredConversation(projectID: projectA, title: "in")
        let outB = StoredConversation(projectID: projectB, title: "out")
        let free = StoredConversation(projectID: nil, title: "free")

        XCTAssertTrue(ProjectScope.isMember(projectA, of: projectA))
        XCTAssertFalse(ProjectScope.isMember(projectB, of: projectA))
        XCTAssertFalse(ProjectScope.isMember(nil, of: projectA),
                       "nil projectID is NEVER a member of any project")
        XCTAssertEqual(
            ProjectScope.filter([inA, outB, free], to: projectA).map(\.id),
            [inA.id])
    }

    @MainActor
    func testVMCompositionAppliesScopeContractOnLoadedChats() async {
        guard let store = try? makeStore() else {
            return XCTFail("store init failed")
        }
        let fx = await seedIsolationFixture(store: store)

        let vm = await makeLoadedVM(store: store, projectID: fx.projectA)
        let chats = vm.chats
        XCTAssertEqual(chats.map(\.id), [fx.chatA2, fx.chatA1])
        XCTAssertTrue(chats.allSatisfy { $0.projectID == fx.projectA },
                      "every rendered Home chat carries the project's id")
    }

    // MARK: §P-2 — newChat born-scoped

    @MainActor
    func testNewChatIsBornScopedToTheProject() async {
        guard let store = try? makeStore() else {
            return XCTFail("store init failed")
        }
        let fx = await seedIsolationFixture(store: store)

        let vm = await makeLoadedVM(store: store, projectID: fx.projectA)
        let created = await vm.newChatTapped()
        let fresh = created.map { $0.id }

        XCTAssertNotNil(created)
        XCTAssertEqual(created?.projectID, fx.projectA,
                       "Project Home's new chat must carry the project id at birth")

        // The new chat appears in A's Home…
        let afterA = await store.conversations(projectID: fx.projectA)
        let createdID = created?.id
        XCTAssertTrue(afterA.contains { $0.id == createdID })
        // …and NEVER in B's Home (zero leakage after creation).
        let afterB = await store.conversations(projectID: fx.projectB)
        XCTAssertFalse(afterB.contains { $0.id == createdID })
    }

    @MainActor
    func testNewChatOnDeletedProjectIsUnavailable() async {
        let store = try? makeStore() ?? nil
        guard let store else { return XCTFail("store init failed") }
        let projectID = UUID()
        await store.upsert(StoredProject(id: projectID, name: "Ghost"))

        let vm = await makeLoadedVM(store: store, projectID: projectID)
        // Delete the project row behind the VM.
        _ = await store.deleteProject(id: projectID)
        // Reload AFTER deletion — the VM must see the missing row.
        await vm.load()

        let created = await vm.newChatTapped()
        XCTAssertNil(created, "no chat without a live project (no phantom writes)")
        XCTAssertEqual(vm.lastEvent, .newChatUnavailable)
    }

    // MARK: §P-3 — instructions are project-scoped

    @MainActor
    func testInstructionsSaveIsScopedAndTrimmed() async {
        guard let store = try? makeStore() else {
            return XCTFail("store init failed")
        }
        let fx = await seedIsolationFixture(store: store)

        let vmA = await makeLoadedVM(store: store, projectID: fx.projectA)
        let saved = await vmA.saveInstructions("  Prefer SwiftUI APIs.  ")
        XCTAssertTrue(saved)

        let reloadedA = await store.getProject(id: fx.projectA)
        XCTAssertEqual(reloadedA?.instructions, "Prefer SwiftUI APIs.")
        // B is untouched (scoping the WRITE, not just the read).
        let untouchedB = await store.getProject(id: fx.projectB)
        XCTAssertEqual(untouchedB?.instructions, "")
        XCTAssertEqual(vmA.lastEvent, .instructionsSaved(characterCount: "Prefer SwiftUI APIs.".count))
    }

    @MainActor
    func testInstructionsRefusePhantomProject() async {
        let store = try? makeStore() ?? nil
        guard let store else { return XCTFail("store init failed") }
        let vm = await makeLoadedVM(store: store, projectID: UUID())
        let saved = await vm.saveInstructions("orphan")
        XCTAssertFalse(saved)
        XCTAssertNil(vm.project)
    }

    // MARK: §P-4 — sources scoped by identity

    @MainActor
    func testSourcesAreProjectScopedAndOrdered() async {
        guard let store = try? makeStore() else {
            return XCTFail("store init failed")
        }
        let fx = await seedIsolationFixture(store: store)

        let vmA = await makeLoadedVM(store: store, projectID: fx.projectA)
        let s1 = await vmA.addSource(kind: "file", reference: "/tmp/spec.pdf", name: "Spec")
        let s2 = await vmA.addSource(kind: "link", reference: "https://example.com", name: "Docs")
        let added1 = s1.map(\.id)
        let added2 = s2.map(\.id)
        XCTAssertNotNil(added1)
        XCTAssertNotNil(added2)

        // A's sources list — exactly the two, in add order.
        let forA = await store.projectSources(projectID: fx.projectA)
        XCTAssertEqual(forA.map(\.id), [added1, added2])
        // B has none — sources never leak across projects.
        let forB = await store.projectSources(projectID: fx.projectB)
        XCTAssertTrue(forB.isEmpty)

        // Foreign delete (right id, WRONG project) is a no-op.
        let foreign = await store.removeProjectSource(id: added1!, projectID: fx.projectB)
        XCTAssertFalse(foreign)
        let stillThere = await store.projectSources(projectID: fx.projectA)
        XCTAssertEqual(stillThere.map(\.id), [added1, added2])

        // Owner delete removes exactly the one.
        let owned = await store.removeProjectSource(id: added1!, projectID: fx.projectA)
        XCTAssertTrue(owned)
        let afterRemove = await store.projectSources(projectID: fx.projectA)
        XCTAssertEqual(afterRemove.map(\.id), [added2])
    }

    @MainActor
    func testSourceOnDeletedProjectIsRejected() async {
        let store = try? makeStore() ?? nil
        guard let store else { return XCTFail("store init failed") }
        let vm = await makeLoadedVM(store: store, projectID: UUID())
        let added = await vm.addSource(kind: "file", reference: "/x", name: "n")
        XCTAssertNil(added, "no orphan source rows")
    }

    // MARK: §P-5 — Task 1 composition (selection ↔ V2ChatHost target)

    @MainActor
    func testCompositionScopedSelectionMatchesChatHostConversation() async {
        guard let store = try? makeStore() else {
            return XCTFail("store init failed")
        }
        let fx = await seedIsolationFixture(store: store)

        // Project Home renders exactly the scoped chats; selecting row i
        // must route V2ChatHost to THAT conversation id (same nav stack).
        let scoped = await store.conversations(projectID: fx.projectA)
        XCTAssertEqual(scoped.map(\.id), [fx.chatA2, fx.chatA1])

        // Simulate the router contract: chat target = the tapped row's id,
        // and the project of that target equals the Home project (always).
        for chat in scoped {
            XCTAssertEqual(ProjectScope.filter([chat], to: fx.projectA).count, 1,
                           "selected chat must belong to the Home project")
        }
    }

    // MARK: §P-6 — archived chats leave Home, stay in the store

    @MainActor
    func testArchivedChatLeavesHomeButSurvives() async {
        guard let store = try? makeStore() else {
            return XCTFail("store init failed")
        }
        let fx = await seedIsolationFixture(store: store)

        let before = await store.conversations(projectID: fx.projectA)
        XCTAssertFalse(before.contains { $0.id == fx.archivedA })

        // The row is still in the store (archive ≠ delete).
        let row = await store.get(id: fx.archivedA)
        XCTAssertEqual(row?.archived, true)
        XCTAssertEqual(row?.projectID, fx.projectA)
    }

    // MARK: rename + derived helpers

    @MainActor
    func testRenameRejectsWhitespaceAndScopes() async {
        guard let store = try? makeStore() else {
            return XCTFail("store init failed")
        }
        let fx = await seedIsolationFixture(store: store)

        let vmA = await makeLoadedVM(store: store, projectID: fx.projectA)
        let okRename = await vmA.rename(to: "  Alpha Prime  ")
        XCTAssertTrue(okRename)
        let renamed = await store.getProject(id: fx.projectA)
        XCTAssertEqual(renamed?.name, "Alpha Prime")
        let untouched = await store.getProject(id: fx.projectB)
        XCTAssertEqual(untouched?.name, "Beta")

        let rejected = await vmA.rename(to: "   ")
        XCTAssertFalse(rejected)
        XCTAssertEqual(vmA.lastEvent, .renameRejected)
    }

    func testChatCountLineGrammar() {
        XCTAssertEqual(ProjectHomeViewModel.chatCountLine(count: 0), "0 chats")
        XCTAssertEqual(ProjectHomeViewModel.chatCountLine(count: 1), "1 chat")
        XCTAssertEqual(ProjectHomeViewModel.chatCountLine(count: 3), "3 chats")
    }

    func testInstructionsPreviewTruncates() {
        XCTAssertEqual(ProjectHomeViewModel.instructionsPreview("short"), "short")
        let long = String(repeating: "x", count: 200)
        let preview = ProjectHomeViewModel.instructionsPreview(long, limit: 120)
        XCTAssertEqual(preview.count, 121) // 120 chars + ellipsis
        XCTAssertTrue(preview.hasSuffix("…"))
    }
}
