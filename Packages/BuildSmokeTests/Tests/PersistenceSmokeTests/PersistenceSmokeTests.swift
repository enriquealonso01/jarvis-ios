import XCTest
@testable import Persistence

/// Item 0 smoke: the Persistence migration scaffold. Item 0 ships an in-memory
/// store + `Schema.migrations` scaffold (real GRDB lands in Item 1, feature
/// #4). These tests pin the migration contract NOW so Item 1 cannot break it
/// silently: fresh-store round-trip, migration-chain well-orderedness, and
/// (when GRDB arrives) the same assertions against a real in-memory database.
final class PersistenceSmokeTests: XCTestCase {
    func testMigrationScaffoldOnFreshStore() async {
        // Fresh in-memory store: empty, accepts upsert, returns exactly what
        // was written, count matches. This is the "runs on a fresh database"
        // contract — the in-memory actor stands in for GRDB until Item 1.
        let store = PersistenceStore()
        let count0 = await store.count()
        XCTAssertEqual(count0, 0, "fresh store must start empty")

        let conv = StoredConversation(title: "migration smoke")
        await store.upsert(conv)
        let fetched = await store.get(id: conv.id)
        XCTAssertEqual(fetched, conv)
        let count1 = await store.count()
        XCTAssertEqual(count1, 1)

        // Upsert semantics (not append): same id replaces, count stays 1.
        var updated = conv
        updated.title = "migration smoke v2"
        await store.upsert(updated)
        let count2 = await store.count()
        XCTAssertEqual(count2, 1, "upsert must not duplicate rows")
        let refetched = await store.get(id: conv.id)
        XCTAssertEqual(refetched?.title, "migration smoke v2")
    }

    func testSchemaMigrationChainContract() {
        // The shipped scaffold must always be well-ordered (empty chain is
        // trivially valid); the validator must keep rejecting bad chains.
        XCTAssertTrue(Schema.isWellOrdered(Schema.migrations),
                      "Schema.migrations must satisfy its own well-ordered contract")
        XCTAssertFalse(Schema.isWellOrdered([
            Migration(identifier: "m2", order: 2),
            Migration(identifier: "m1", order: 1),
        ]))
        XCTAssertFalse(Schema.isWellOrdered([
            Migration(identifier: "m1", order: 1),
            Migration(identifier: "m1", order: 2),
        ]), "duplicate identifiers must be rejected")
    }

    func testStoredConversationDefaultsAndCodable() throws {
        let conv = StoredConversation(title: "t")
        XCTAssertTrue(abs(conv.updatedAt.timeIntervalSinceNow) < 5)
        let data = try JSONEncoder().encode(conv)
        let decoded = try JSONDecoder().decode(StoredConversation.self, from: data)
        XCTAssertEqual(decoded, conv)
    }
}
