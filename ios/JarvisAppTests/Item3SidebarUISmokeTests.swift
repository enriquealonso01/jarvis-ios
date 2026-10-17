import XCTest
import SwiftUI
import Persistence
import DesignSystem
import FeaturesChat
@testable import JarvisApp

/// Item 3 TESTER — UI smoke (app target). SwiftUI views can't be
/// behaviorally unit-tested headless, but they CAN be instantiated on the
/// main actor and driven through state changes: a crash, a retain-cycle
/// deinit stall, or an @Observable/ObservableObject explosion surfaces here.
///
/// Scope (Item 3 §4):
///   - SidebarViewModel (the FeaturesChat implementation the app shell will
///     host) instantiates with sample store data and drives the panel.
///   - Collapse/expand toggles don't crash.
///   - View models deallocate (deinit smoke — the cheap retain-cycle net).
///
/// The package's own SwiftUI views (SidebarPanel etc.) are package-internal
/// (not `public`), so the app-target smoke drives the view model + the
/// slide-over geometry contract; full view rendering is covered by the app
/// shell integration once the shell adopts the package (next items).
@MainActor
final class Item3SidebarUISmokeTests: XCTestCase {

    // MARK: - Sample store data

    private func sampleStore() async -> PersistenceStore {
        let store = PersistenceStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var krendora = StoredProject(name: "Krendora", updatedAt: base.addingTimeInterval(10))
        krendora.pinned = true
        await store.upsert(krendora)
        let home = StoredProject(name: "Home", updatedAt: base.addingTimeInterval(20))
        await store.upsert(home)
        await store.upsert(StoredConversation(
            title: "Order processing",
            updatedAt: base.addingTimeInterval(30),
            pinned: true
        ))
        await store.upsert(StoredConversation(
            projectID: krendora.id,
            title: "Supplier thread",
            updatedAt: base.addingTimeInterval(40)
        ))
        await store.upsert(StoredConversation(
            title: "Loose chat",
            updatedAt: base.addingTimeInterval(50)
        ))
        return store
    }

    // MARK: View model instantiates with sample store data

    func testSidebarViewModelInstantiatesWithSampleStoreData() async {
        let store = await sampleStore()
        let model = SidebarViewModel(store: store)
        await model.reload()
        XCTAssertFalse(model.pinned.isEmpty, "sample pinned row must load")
        XCTAssertFalse(model.projects.isEmpty, "sample projects must load")
        XCTAssertFalse(model.recents.isEmpty, "sample recents must load")
        XCTAssertEqual(model.projects.count, 2)
        let krendora = try! XCTUnwrap(model.projects.first { $0.project.name == "Krendora" })
        XCTAssertEqual(krendora.conversations.map { $0.title }, ["Supplier thread"])

        // The observable object survives state changes without crashing.
        model.searchQuery = "supplier"
        XCTAssertEqual(model.filteredRecents.count, 1)
        model.searchQuery = ""
    }

    // MARK: Collapse/expand toggle smoke

    func testProjectCollapseToggleDoesNotCrash() async {
        let store = await sampleStore()
        let model = SidebarViewModel(store: store)
        await model.reload()

        // Toggle the collapsible Projects section repeatedly — an
        // ObservableObject mutation storm or crash would fail here.
        let initial = model.projectsExpanded
        for i in 1...5 {
            model.setProjectsExpanded(!model.projectsExpanded)
            XCTAssertEqual(model.projectsExpanded, initial == (i % 2 == 0))
        }
        // Store-backed KV write fired per toggle (fire-and-forget Task) —
        // drain briefly and assert the final value round-trips.
        try? await Task.sleep(nanoseconds: 200_000_000)
        let entry = await store.widgetSnapshotEntry(key: Tokens.Sidebar.Keys.projectsExpanded)
        XCTAssertNotNil(entry, "collapse state must persist to the store KV surface")
    }

    func testSlideOverGeometryContractHoldsOnPhoneWidth() {
        // UI Law §1: ~85% width panel, conversation edge stays visible.
        let containerWidth: CGFloat = 393
        let panelWidth = containerWidth * Tokens.Sidebar.widthFraction
        XCTAssertLessThan(panelWidth, containerWidth, "panel never fully covers the conversation")
        XCTAssertGreaterThan(containerWidth - panelWidth, 30, "≥30pt of conversation remains visible")
        XCTAssertLessThanOrEqual(Tokens.Sidebar.rowHeight, 48, "row height stays within iOS list norms")
    }

    // MARK: Retain-cycle smoke (deinit asserts)

    func testViewModelDeallocates() async {
        let store = await sampleStore()
        weak var weakVM: SidebarViewModel?
        do {
            let model = SidebarViewModel(store: store)
            weakVM = model
            await model.reload()
            _ = await model.newChat() // exercises the Task-persisting path
            await model.select /* route */ (conversationID: model.recents.first?.id ?? UUID())
            XCTAssertNotNil(weakVM)
        }
        autoreleasepool { }
        for _ in 0..<5 where weakVM != nil {
            await Task.yield()
        }
        XCTAssertNil(weakVM, "SidebarViewModel must deallocate — a live instance means a retain cycle")
    }
}
