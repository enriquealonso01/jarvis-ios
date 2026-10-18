import XCTest
import DesignSystem
import Foundation
import Persistence
@testable import FeaturesSidebar

/// Item 3 (#2) QA — Sidebar UI logic per UI Law §1. Pure-logic only
/// (no SwiftUI view instantiation, no UIKit): the sidebar contracts are
/// data shaping + store mechanics, both Linux-runnable in principle.
@MainActor
final class Item3SidebarQATests: XCTestCase {

    // MARK: - Pinned mixes chats + projects, newest first

    func testpinnedInterleavesChatsAndProjectsByRecency() async {
        let store = PersistenceStore()
        let model = SidebarViewModel(store: store)

        let projectID = UUID()
        var project = StoredProject(id: projectID, name: "Krendora", updatedAt: Date(timeIntervalSince1970: 100))
        project.pinned = true
        await store.upsert(project)

        let pinnedChat = StoredConversation(
            title: "Order processing",
            updatedAt: Date(timeIntervalSince1970: 300),
            pinned: true
        )
        await store.upsert(pinnedChat)
        // Unpinned chat + unpinned project must NOT appear in Pinned.
        await store.upsert(StoredConversation(title: "Loose chat", updatedAt: Date(timeIntervalSince1970: 400)))
        await store.upsert(StoredProject(name: "Loose project", updatedAt: Date(timeIntervalSince1970: 350)))

        await model.load()

        XCTAssertEqual(model.pinnedEntries.count, 2)
        XCTAssertEqual(model.pinnedEntries[0].kind, .chat(id: pinnedChat.id))
        XCTAssertEqual(model.pinnedEntries[0].updatedAt, Date(timeIntervalSince1970: 300))
        XCTAssertEqual(model.pinnedEntries[1].kind, .project(id: projectID))
        XCTAssertEqual(model.pinnedEntries[1].title, "Krendora")
    }

    func testarchivedChatsNeverAppearAnywhere() async {
        let store = PersistenceStore()
        let model = SidebarViewModel(store: store)

        await store.upsert(StoredConversation(
            title: "Archived",
            updatedAt: Date(timeIntervalSince1970: 500),
            pinned: true,
            archived: true
        ))
        await store.upsert(StoredConversation(title: "Visible", updatedAt: Date(timeIntervalSince1970: 200)))

        await model.load()

        XCTAssertTrue(model.pinnedEntries.isEmpty)
        XCTAssertEqual(model.recentChats.map(\.title), ["Visible"])
    }

    // MARK: - Projects section: pinned first, chats attached

    func testprojectGroupsOrderPinnedFirstThenNewest() async {
        let store = PersistenceStore()
        let model = SidebarViewModel(store: store)

        var pinnedOld = StoredProject(name: "Pinned old", updatedAt: Date(timeIntervalSince1970: 10))
        pinnedOld.pinned = true
        await store.upsert(pinnedOld)
        await store.upsert(StoredProject(name: "Newest", updatedAt: Date(timeIntervalSince1970: 900)))
        await store.upsert(StoredProject(name: "Middle", updatedAt: Date(timeIntervalSince1970: 500)))

        await model.load()

        XCTAssertEqual(model.projectGroups.map(\.project.name), ["Pinned old", "Newest", "Middle"])
    }

    func testprojectGroupCarriesItsChatsNewestFirst() async {
        let store = PersistenceStore()
        let model = SidebarViewModel(store: store)

        let project = StoredProject(name: "Home")
        await store.upsert(project)
        await store.upsert(StoredConversation(
            projectID: project.id, title: "Older", updatedAt: Date(timeIntervalSince1970: 10)
        ))
        await store.upsert(StoredConversation(
            projectID: project.id, title: "Newer", updatedAt: Date(timeIntervalSince1970: 20)
        ))
        // Unrelated chat must not leak into the group.
        await store.upsert(StoredConversation(title: "Loose", updatedAt: Date(timeIntervalSince1970: 30)))

        await model.load()

        let group = model.projectGroups.first
        XCTAssertNotNil(group)
        XCTAssertEqual(group?.conversations.map(\.title), ["Newer", "Older"])
    }

    // MARK: - Recents grouped by project (pure function)

    func testrecentsGroupingBucketsAndOrdersByProject() {
        let projectA = UUID()
        let projectB = UUID()
        let projects = [
            StoredProject(id: projectA, name: "A"),
            StoredProject(id: projectB, name: "B"),
        ]
        // Deliberately interleaved: recents are combined chronological.
        let chats = [
            StoredConversation(projectID: nil, title: "loose-1", updatedAt: Date(timeIntervalSince1970: 10)),
            StoredConversation(projectID: projectA, title: "a-1", updatedAt: Date(timeIntervalSince1970: 20)),
            StoredConversation(projectID: projectB, title: "b-1", updatedAt: Date(timeIntervalSince1970: 30)),
            StoredConversation(projectID: projectA, title: "a-2", updatedAt: Date(timeIntervalSince1970: 40)),
            StoredConversation(projectID: nil, title: "loose-2", updatedAt: Date(timeIntervalSince1970: 50)),
        ]

        let groups = SidebarViewModel.groupedByProject(chats: chats, projects: projects)

        // Group order = first appearance in the recents stream.
        XCTAssertEqual(groups.map(\.projectID), [nil, projectA, projectB])
        XCTAssertEqual(groups[0].conversations.map(\.title), ["loose-2", "loose-1"])
        XCTAssertNil(groups[0].projectName)
        XCTAssertEqual(groups[1].conversations.map(\.title), ["a-2", "a-1"])
        XCTAssertEqual(groups[1].projectName, "A")
        XCTAssertEqual(groups[2].projectName, "B")
    }

    func testrecentsGroupingEmptyInputGivesNoGroups() {
        let groups = SidebarViewModel.groupedByProject(chats: [], projects: [])
        XCTAssertTrue(groups.isEmpty)
    }

    // MARK: - List mechanics (UI Law §8)

    func testpinUnpinConversationRoundTrip() async {
        let store = PersistenceStore()
        let model = SidebarViewModel(store: store)

        let chat = StoredConversation(title: "Chat")
        await store.upsert(chat)
        await model.load()
        XCTAssertTrue(model.pinnedEntries.isEmpty)

        await model.setPinned(true, conversationID: chat.id)
        XCTAssertEqual(model.pinnedEntries.map(\.title), ["Chat"])

        await model.setPinned(false, conversationID: chat.id)
        XCTAssertTrue(model.pinnedEntries.isEmpty)
    }

    func testpinProjectRoundTrip() async {
        let store = PersistenceStore()
        let model = SidebarViewModel(store: store)

        let project = StoredProject(name: "Project")
        await store.upsert(project)
        await model.load()
        XCTAssertTrue(model.pinnedEntries.isEmpty)

        await model.setPinned(true, projectID: project.id)
        XCTAssertEqual(model.pinnedEntries.map(\.title), ["Project"])
        let hoisted1 = await store.pinnedProjects().map(\.id)
        XCTAssertEqual(hoisted1, [project.id])
    }

    func testrenameTrimsAndRejectsEmpty() async {
        let store = PersistenceStore()
        let model = SidebarViewModel(store: store)

        let chat = StoredConversation(title: "Before")
        await store.upsert(chat)

        await model.rename(conversationID: chat.id, to: "   ")
        let hoisted2 = await store.get(id: chat.id)?.title
        XCTAssertEqual(hoisted2, "Before")

        await model.rename(conversationID: chat.id, to: "  After  ")
        let hoisted3 = await store.get(id: chat.id)?.title
        XCTAssertEqual(hoisted3, "After")
    }

    func testarchiveRemovesFromRecentsButRowStaysSearchable() async {
        let store = PersistenceStore()
        let model = SidebarViewModel(store: store)

        let chat = StoredConversation(title: "To archive")
        await store.upsert(chat)

        await model.archive(conversationID: chat.id)

        XCTAssertTrue(model.recentChats.isEmpty)
        // Archive never deletes: the row persists (stays searchable, UI Law §8).
        let hoisted4 = await store.get(id: chat.id)?.archived ?? false
        XCTAssertTrue(hoisted4)
    }

    func testdeleteRemovesRow() async {
        let store = PersistenceStore()
        let model = SidebarViewModel(store: store)

        let chat = StoredConversation(title: "Doomed")
        await store.upsert(chat)

        let deleted = await model.delete(conversationID: chat.id)
        XCTAssertTrue(deleted)
        let hoisted5 = await store.get(id: chat.id)
        XCTAssertNil(hoisted5)
        XCTAssertTrue(model.recentChats.isEmpty)
    }

    // MARK: - Add-ons bar contents (UI Law §1 slot)

    func testaddOnsBarHasTheFourStandardSlotsInOrder() {
        XCTAssertEqual(SidebarAddOn.standard.map(\.id), ["runs", "recordings", "memory", "schedules"])
        XCTAssertEqual(SidebarAddOn.standard.map(\.title),
            ["Agent Runs", "Recordings", "Memory", "Schedules"])
        // Every slot renders with an icon.
        XCTAssertTrue(SidebarAddOn.standard.allSatisfy { !$0.systemImage.isEmpty })
    }

    func testaddOnIDsRoundTrip() {
        for addOn in SidebarAddOn.standard {
            XCTAssertNotNil(SidebarAddOnID(rawValue: addOn.id))
        }
        XCTAssertEqual(SidebarAddOnID.allCases.count, 4)
    }

    // MARK: - Slide-over geometry contract (UI Law §1)

    func testsidebarWidthTokenIsApprox85Percent() {
        // Binding law: ~85% width slide-over on iPhone.
        XCTAssertTrue(Tokens.Sidebar.widthFraction >= 0.80)
        XCTAssertTrue(Tokens.Sidebar.widthFraction <= 0.90)
    }

    // MARK: - Project pin persistence (Item 3 migration)

    func testprojectPinnedFlagRoundTrips() async {
        let store = PersistenceStore()
        var project = StoredProject(name: "Pin me")
        await store.upsert(project)
        let hoisted6 = await store.pinnedProjects().isEmpty
        XCTAssertTrue(hoisted6)

        project.pinned = true
        await store.upsert(project)
        let hoisted7 = await store.pinnedProjects().map(\.id)
        XCTAssertEqual(hoisted7, [project.id])
    }
}
