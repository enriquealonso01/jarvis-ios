import XCTest
@testable import FeaturesChat
import Persistence

/// Item 13 QA: PDF export engine — document model from REAL stored messages,
/// print-policy fidelity (Item 11 contract), no-fake-UI pins.
/// macOS-lane safe: pure engine tests, no UIKit, no fake UI.
@MainActor
final class Item13ChatExportQATests: XCTestCase {

    // MARK: - Fixture

    private func makeStore() throws -> PersistenceStore {
        let dir = NSTemporaryDirectory() + "item13-qa-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return try PersistenceStore(path: dir + "/qa.sqlite")
    }

    private func seed(_ store: PersistenceStore,
                      title: String = "Breck day 3 — trip planning") async throws -> (UUID, [UUID]) {
        let conversation = StoredConversation(title: title)
        try await store.upsert(conversation)
        let richJSON = """
        ```jarvis-rich
        {"schemaVersion":1,"blocks":[{"id":"qa-chart-1","type":"chart","version":"1.0.0","fallbackText":"Spend chart","props":{"kind":"bar","title":"Spend","points":[{"label":"Mon","value":12.5},{"label":"Tue","value":9.0}]},"print":{"strategy":"snapshot"}}]}
        ```
        """
        let m1 = StoredMessage(conversationID: conversation.id, role: .user,
                               content: "What's the plan for day three?")
        let m2 = StoredMessage(conversationID: conversation.id, role: .assistant,
                               content: "Day three is the mellow one: breakfast at 8, then the gondola.")
        let m3 = StoredMessage(conversationID: conversation.id, role: .assistant,
                               content: richJSON)
        let m4 = StoredMessage(conversationID: conversation.id, role: .system,
                               content: "internal tool row")
        for m in [m1, m2, m3, m4] {
            try await store.upsert(m)
        }
        // QA-pin: tests select messages via ids[0] (the USER text row) and
        // build selections from the message ids — the first element is the
        // conversation id so selection tests can address the transcript.
        return (conversation.id, [m1.id, m2.id, m3.id, m4.id])
    }

    // MARK: - Whole-chat build

    func testWholeChatBuildsDocumentFromRealStore() async throws {
        let store = try makeStore()
        let (conversationID, _) = try await seed(store)
        let doc = try await ChatExportEngine.buildDocument(conversationID: conversationID, store: store)
        XCTAssertEqual(doc.title, "Breck day 3 — trip planning")
        XCTAssertEqual(doc.messageCount, 4)
        // 4 printable blocks: user text, assistant text, rich, system-omitted.
        XCTAssertEqual(doc.blocks.count, 4)
    }

    func testMessagesOrderedOldestFirst() async throws {
        let store = try makeStore()
        let conversation = StoredConversation(title: "Order")
        try await store.upsert(conversation)
        let base = Date(timeIntervalSince1970: 1_000_000)
        // Insert newer-first, but give explicit createdAt stamps so the export
        // contract (sort by createdAt, oldest first) is actually exercised:
        // with default `Date()` stamps, wall-clock order would contradict the
        // insert order and the fixture itself would be wrong.
        let newer = StoredMessage(conversationID: conversation.id, role: .user, content: "later",
                                  createdAt: base.addingTimeInterval(60))
        let older = StoredMessage(conversationID: conversation.id, role: .assistant, content: "earlier",
                                  createdAt: base)
        try await store.upsert(newer)
        try await store.upsert(older)
        let doc = try await ChatExportEngine.buildDocument(conversationID: conversation.id, store: store)
        XCTAssertEqual(doc.blocks.first?.kind,
                       .text("earlier"),
                       "export must read oldest-first regardless of insert order")
    }

    // MARK: - Selection build

    func testSelectionExportsOnlyPickedIDsInOrder() async throws {
        let store = try makeStore()
        let (conversationID, ids) = try await seed(store)
        // Pick assistant text then user text — order must be preserved.
        let doc = try await ChatExportEngine.buildDocument(
            conversationID: conversationID,
            selectedMessageIDs: [ids[1], ids[0]],
            store: store)
        XCTAssertEqual(doc.messageCount, 2)
        guard case .text(let first) = doc.blocks.first?.kind else {
            return XCTFail("expected text block first")
        }
        XCTAssertTrue(first.contains("mellow one"))
    }

    func testSelectionWithUnknownIDThrows() async throws {
        let store = try makeStore()
        let (conversationID, ids) = try await seed(store)
        do {
            _ = try await ChatExportEngine.buildDocument(
                conversationID: conversationID,
                selectedMessageIDs: [ids[0], UUID()],
                store: store)
            XCTFail("expected unknownMessageIDs")
        } catch let error as ChatExportEngine.ExportError {
            guard case .unknownMessageIDs(let bad) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(bad.count, 1)
        }
    }

    func testMissingConversationThrows() async throws {
        let store = try makeStore()
        do {
            _ = try await ChatExportEngine.buildDocument(conversationID: UUID(), store: store)
            XCTFail("expected conversationNotFound")
        } catch let error as ChatExportEngine.ExportError {
            XCTAssertEqual(error, .conversationNotFound)
        }
    }

    func testEmptyConversationThrowsNoContent() async throws {
        let store = try makeStore()
        let conversation = StoredConversation(title: "Empty")
        try await store.upsert(conversation)
        do {
            _ = try await ChatExportEngine.buildDocument(conversationID: conversation.id, store: store)
            XCTFail("expected noContent")
        } catch let error as ChatExportEngine.ExportError {
            XCTAssertEqual(error, .noContent)
        }
    }

    // MARK: - Item 11 fidelity contract (print strategies)

    func testRichPayloadDecodesToRichBlocks() async throws {
        let store = try makeStore()
        let (conversationID, ids) = try await seed(store)
        let doc = try await ChatExportEngine.buildDocument(
            conversationID: conversationID,
            selectedMessageIDs: [ids[2]],
            store: store)
        guard case .richBlocks(let blocks)? = doc.blocks.first?.kind else {
            return XCTFail("expected richBlocks")
        }
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.type, .chart)
    }

    func testSystemAndToolRowsSummarizeNeverBlank() async throws {
        let store = try makeStore()
        let (conversationID, ids) = try await seed(store)
        let doc = try await ChatExportEngine.buildDocument(
            conversationID: conversationID,
            selectedMessageIDs: [ids[3]],
            store: store)
        guard case .omitted(let line)? = doc.blocks.first?.kind else {
            return XCTFail("expected omitted")
        }
        XCTAssertTrue(line.contains("system"), "omitted line must say which role was skipped")
        XCTAssertFalse(line.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    func testEmptyUserMessageNeverProducesBlankBlock() async throws {
        let block = ChatExportEngine.messageBlock(StoredMessage(
            conversationID: UUID(), role: .user, content: "   "))
        guard case .text(let text) = block.kind else { return XCTFail("expected text") }
        XCTAssertEqual(text, "(empty message)", "the never-blank law: whitespace-only rows print a visible placeholder")
    }

    // MARK: - Options

    func testOptionsStandardCarriesAllToggles() {
        let options = ChatExportEngine.Options.standard
        XCTAssertTrue(options.includeCover)
        XCTAssertTrue(options.includeHeaders)
        XCTAssertTrue(options.includePageNumbers)
        XCTAssertTrue(options.includeTimestamps)
        let custom = ChatExportEngine.Options(includeCover: false, includeHeaders: false,
                                              includePageNumbers: false, includeTimestamps: false)
        XCTAssertFalse(custom.includeCover)
    }

    func testPrintDefaultsCoverEveryBlockType() {
        // Item 13 consumes RichPrintDefaults — the mapping must stay total.
        for type in RichBlockType.allCases {
            let strategy = RichPrintDefaults.strategy(for: type)
            XCTAssertTrue(RichPrintPolicy.Strategy.allCases.contains(strategy),
                          "every block type needs a print strategy")
        }
        XCTAssertEqual(RichPrintDefaults.strategy(for: .chart), .snapshot)
        XCTAssertEqual(RichPrintDefaults.strategy(for: .fallback), .summary)
        XCTAssertEqual(RichPrintDefaults.strategy(for: .text), .native)
    }
}
