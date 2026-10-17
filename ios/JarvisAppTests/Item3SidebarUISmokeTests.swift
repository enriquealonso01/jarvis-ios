import XCTest
import SwiftUI
import Persistence
import DesignSystem
import FeaturesChat
@testable import JarvisApp

/// Item 3 BUILDER — app-target smoke (feature #2, UI Law §1).
///
/// SwiftUI view bodies can't be behaviorally asserted headless, but they CAN
/// be instantiated on the main actor and driven through state changes: a
/// crash, a retain cycle, or an @Observable explosion surfaces here. The
/// store-contract suite (FeaturesChatTests.Item3SidebarCorrectnessQATests)
/// holds the view model to its behavioral contract; this suite covers the
/// shell + panel wiring in the app target.
@MainActor
final class Item3SidebarUISmokeTests: XCTestCase {

    // MARK: - Sample store data

    private func sampleStore() async -> PersistenceStore {
        let store = PersistenceStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var krendora = StoredProject(name: "Krendora", updatedAt: base.addingTimeInterval(10))
        krendora.pinned = true
        await store.upsert(krendora)
        await store.upsert(StoredProject(name: "Home", updatedAt: base.addingTimeInterval(20)))
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

    // MARK: Shell instantiates + drives through state changes

    func testShellInstantiatesWithSampleStoreAndDrives() async {
        let store = await sampleStore()
        let shell = V2SidebarShell(store: store)

        // Instantiate the panel body the way the shell hosts it (view bodies
        // are lazy; forcing evaluation via UIHostingController is the cheap
        // way to catch layout crashes).
        let vm = FeaturesChat.SidebarViewModel(store: store)
        await vm.restoreState()
        await vm.reload()
        let panel = SidebarPanelView(vm: vm) { _ in }
        let hosting = UIHostingController(rootView: panel)
        XCTAssertNotNil(hosting.view)

        // Open/close round trip (write-through completes before returning).
        await vm.setOpen(true)
        XCTAssertTrue(vm.isOpen)
        await vm.setOpen(false)
        XCTAssertFalse(vm.isOpen)

        // Collapse toggle.
        await vm.setProjectsExpanded(false)
        XCTAssertFalse(vm.projectsExpanded)
        await vm.setProjectsExpanded(true)
        XCTAssertTrue(vm.projectsExpanded)

        _ = shell // held through the assertions above
    }

    // MARK: View model drives the panel with sample data

    func testSidebarViewModelDrivesPanelWithSampleStoreData() async {
        let store = await sampleStore()
        let model = FeaturesChat.SidebarViewModel(store: store)
        await model.restoreState()
        await model.reload()

        XCTAssertEqual(model.pinned.count, 1, "sample pinned row must load")
        XCTAssertEqual(model.projects.count, 2, "sample projects must load")
        XCTAssertFalse(model.recents.isEmpty, "sample recents must load")
        let krendora = try! XCTUnwrap(model.projects.first { $0.project.name == "Krendora" })
        XCTAssertEqual(krendora.conversations.map { $0.title }, ["Supplier thread"])

        // Client-side filter narrows recents (Item 6 replaces the field).
        model.searchQuery = "supplier"
        XCTAssertEqual(model.filteredRecents.count, 1)
        model.searchQuery = ""
        XCTAssertEqual(model.filteredRecents.count, model.recents.count)
    }

    // MARK: Geometry contract (UI Law §1, ~85% slide-over above the chat)

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
        weak var weakVM: FeaturesChat.SidebarViewModel?
        do {
            let model = FeaturesChat.SidebarViewModel(store: store)
            weakVM = model
            await model.reload()
            _ = await model.newChat() // exercises the persisting path
            await model.select(conversationID: model.recents.first?.id ?? UUID())
            XCTAssertNotNil(weakVM)
        }
        autoreleasepool { }
        for _ in 0..<5 where weakVM != nil {
            await Task.yield()
        }
        XCTAssertNil(weakVM, "SidebarViewModel must deallocate — a live instance means a retain cycle")
    }
}
