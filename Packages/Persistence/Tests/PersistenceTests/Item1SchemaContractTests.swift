import Foundation
import XCTest

@testable import Persistence

/// Item 1 TESTER schema-contract pin (feature #4 / plan §5.2).
///
/// Behavioral existence proof: right after a clean migration from an empty
/// store, EVERY shipped table must be queryable through its public store API
/// without throwing, and the messages table must round-trip its §5.2 column
/// contract (local UUID identity + branchId/branchIndex). Uses only the
/// public Persistence API — no raw SQL, no GRDB import in tests.
final class Item1SchemaContractTests: XCTestCase {

    private func tempDBPath(_ label: String) -> String {
        let dir = NSTemporaryDirectory() + "item1-schema-\(label)-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/store.sqlite"
    }

    func testFreshMigrationExposesEveryShippedTable() async throws {
        // File-backed so the migration provably ran against a real empty DB.
        let store = try PersistenceStore(path: tempDBPath("contract"))

        // conversations
        let convCount = await store.count()
        XCTAssertEqual(convCount, 0, "conversations must exist and start empty")

        // messages
        let conv = StoredConversation(title: "schema contract")
        await store.upsert(conv)
        let messageCount = await store.messageCount(conversationID: conv.id)
        XCTAssertEqual(messageCount, 0, "messages must exist and start empty")

        // branches
        let branches = try await store.branches(conversationID: conv.id)
        XCTAssertTrue(branches.isEmpty, "branches must exist and start empty")

        // outbox
        let outbox = await store.outboxCount()
        XCTAssertEqual(outbox, 0, "outbox must exist and start empty")

        // run_cards
        let cards = await store.runCards(conversationID: conv.id)
        XCTAssertTrue(cards.isEmpty, "run_cards must exist and start empty")

        // widget_snapshot (App-Group table)
        let snapshot = await store.widgetSnapshotEntry(key: "status")
        XCTAssertNil(snapshot, "widget_snapshot must exist and start empty")

        // messages_fts (FTS5 over message content): a MATCH on an empty index
        // must return empty rather than erroring — proves the virtual table exists.
        let hits = try await store.searchMessages(matching: "anything")
        XCTAssertTrue(hits.isEmpty, "messages_fts must exist and query cleanly when empty")
    }

    func testMessagesTableRoundTripsLocalUUIDAndBranchColumns() async throws {
        let store = PersistenceStore()
        let conv = StoredConversation(title: "column contract")
        await store.upsert(conv)

        // Local UUID is the row identity: caller-supplied id round-trips.
        let localID = UUID()
        let branchID = "conv-\(localID.uuidString.prefix(8))-b1"
        let message = StoredMessage(
            id: localID,
            conversationID: conv.id,
            role: .user,
            content: "branch column contract",
            branchID: branchID,
            branchIndex: 1
        )
        await store.upsert(message)

        let fetched = await store.getMessage(id: localID)
        XCTAssertEqual(fetched?.id, localID, "local UUID must be the persisted identity")
        XCTAssertEqual(fetched?.branchID, branchID, "branch_id must round-trip")
        XCTAssertEqual(fetched?.branchIndex, 1, "branch_index must round-trip")

        // Trunk default: branchID nil, branchIndex 0.
        let trunk = StoredMessage(conversationID: conv.id, role: .assistant, content: "trunk")
        await store.upsert(trunk)
        let fetchedTrunk = await store.getMessage(id: trunk.id)
        XCTAssertNil(fetchedTrunk?.branchID)
        XCTAssertEqual(fetchedTrunk?.branchIndex, 0)
    }
}
