import Foundation
import XCTest

@testable import Persistence

final class PersistenceTests: XCTestCase {
    func testMigrationChainValidator() {
        XCTAssertTrue(Schema.isWellOrdered([
            Migration(identifier: "a", order: 1),
            Migration(identifier: "b", order: 2),
        ]))
        XCTAssertFalse(Schema.isWellOrdered([
            Migration(identifier: "b", order: 2),
            Migration(identifier: "a", order: 1),
        ]))
        // duplicate identifiers = not well-ordered
        XCTAssertFalse(Schema.isWellOrdered([
            Migration(identifier: "a", order: 1),
            Migration(identifier: "a", order: 2),
        ]))
        XCTAssertTrue(Schema.isWellOrdered(Schema.migrations))
    }

    func testStoreUpsertGet() async {
        let store = PersistenceStore()
        let conv = StoredConversation(title: "Krendora orders")
        await store.upsert(conv)
        let fetched = await store.get(id: conv.id)
        XCTAssertEqual(fetched, conv)
        let count = await store.count()
        XCTAssertEqual(count, 1)
    }
}
