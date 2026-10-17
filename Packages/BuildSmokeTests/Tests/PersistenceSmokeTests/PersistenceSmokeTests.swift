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

        // Whole-second dates: GRDB .datetime storage is not bit-exact for
        // sub-millisecond Date precision, so round-trip equality needs
        // storage-precision dates (builder's convention, CI run 39063444498).
        let conv = StoredConversation(
            title: "migration smoke",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
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

    func testStoredConversationDefaults() {
        let conv = StoredConversation(title: "t")
        XCTAssertTrue(abs(conv.updatedAt.timeIntervalSinceNow) < 5)
        // Equality identity: same id + title + date compares equal.
        let twin = StoredConversation(id: conv.id, title: "t", updatedAt: conv.updatedAt)
        XCTAssertEqual(twin, conv)
        XCTAssertNotEqual(StoredConversation(id: conv.id, title: "other", updatedAt: conv.updatedAt), conv)
    }

    // MARK: - Item 1 extensions (GRDB is real now; contract only grows)

    func testV1MigrationIsRegisteredAndWellOrdered() {
        // v1 ships exactly one migration, first in the chain.
        XCTAssertEqual(Schema.migrations.first, Schema.Migrations.v1)
        XCTAssertEqual(Schema.Migrations.v1.identifier, "v1.core-tables")
        XCTAssertEqual(Schema.Migrations.v1.order, 1)
        XCTAssertTrue(Schema.isWellOrdered(Schema.migrations))
    }

    func testFreshStoreOnRealGRDB() async {
        // The Item 0 in-memory contract, now against real GRDB tables:
        // empty start, upsert round-trip, upsert-not-append.
        let store = PersistenceStore()
        let count0 = await store.count()
        XCTAssertEqual(count0, 0, "fresh store must start empty")

        // Same whole-second-date convention for the GRDB round-trip equality.
        let conv = StoredConversation(
            title: "grdb smoke",
            createdAt: Date(timeIntervalSince1970: 1_700_001_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_001_000)
        )
        await store.upsert(conv)
        let fetched = await store.get(id: conv.id)
        XCTAssertEqual(fetched, conv)
        let countGRDB = await store.count()
        XCTAssertEqual(countGRDB, 1)

        var updated = conv
        updated.title = "grdb smoke v2"
        await store.upsert(updated)
        let countAfterUpdate = await store.count()
        XCTAssertEqual(countAfterUpdate, 1, "upsert must not duplicate rows")
    }

    func testMessagePageSizeContract() {
        // The UI pagination contract: 50 messages per page.
        XCTAssertEqual(PersistenceStore.messagePageSize, 50)
    }
}
