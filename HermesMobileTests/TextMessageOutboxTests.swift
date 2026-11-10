import XCTest
@testable import HermesMobile

/// `TextMessageOutbox` and `LocalPendingChatRegistry`: the offline-first queue for
/// typed messages — enqueue, persistence, drain order, stop-at-failure, retry, and
/// the optimistic row shape the transcript shows.
@MainActor
final class TextMessageOutboxTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makeOutbox() -> TextMessageOutbox {
        TextMessageOutbox(url: directory.appendingPathComponent("outbox.json"))
    }

    private func makeRegistry() -> LocalPendingChatRegistry {
        LocalPendingChatRegistry(url: directory.appendingPathComponent("chats.json"))
    }

    private let server = URL(string: "https://jarvis.example")!
    private lazy var keyA = ChatDraftKey.hermesSession(server: server, connectionID: UUID(), profile: "default", key: nil)
    private lazy var keyB = ChatDraftKey.hermesSession(server: server, connectionID: UUID(), profile: "default", key: "abc")

    /// A queued prompt appears at once as a user row whose id and display kind carry
    /// its pending state, and both queue and registry persist across a new instance
    /// (a relaunch reading the same file).
    func testEnqueuePersistsAndShowsPendingRow() throws {
        let outbox = makeOutbox()
        let entry = TextOutboxEntry(id: "e1", chatKey: TextMessageOutbox.chatKey(for: keyA), text: "Ping",
                                    createdAt: Date(timeIntervalSince1970: 100))
        outbox.add(entry)
        outbox.add(TextOutboxEntry(id: "e2", chatKey: TextMessageOutbox.chatKey(for: keyB), text: "Other chat",
                                   createdAt: Date(timeIntervalSince1970: 200)))

        // The row the transcript renders: user role, the sent text, status in the display kind.
        let row = TextMessageOutbox.pendingMessage(for: entry)
        XCTAssertEqual(row.role, "user")
        XCTAssertEqual(row.content, "Ping")
        XCTAssertEqual(row.messageId, "text-pending-e1")
        XCTAssertEqual(row.displayKind, TextMessageOutbox.pendingDisplayKind)

        // A failed drain re-renders the same row as failed without changing its text.
        var failed = entry
        failed.failed = true
        XCTAssertEqual(TextMessageOutbox.pendingMessage(for: failed).displayKind,
                       TextMessageOutbox.pendingFailedDisplayKind)

        // entries(for:) is scoped to one chat; other chats stay queued.
        XCTAssertEqual(outbox.entries(for: TextMessageOutbox.chatKey(for: keyA)).map(\.id), ["e1"])
        XCTAssertEqual(outbox.entries(for: TextMessageOutbox.chatKey(for: keyB)).map(\.id), ["e2"])
        XCTAssertEqual(outbox.chatKeysWithEntries(), [TextMessageOutbox.chatKey(for: keyA), TextMessageOutbox.chatKey(for: keyB)])

        // Persistence: a fresh instance over the same file sees the same queue.
        let relaunched = makeOutbox()
        XCTAssertEqual(relaunched.entries(for: TextMessageOutbox.chatKey(for: keyA)).map(\.text), ["Ping"])

        // messageID/entryID round-trip
        XCTAssertEqual(TextMessageOutbox.entryID(fromMessageID: "text-pending-e1"), "e1")
        XCTAssertNil(TextMessageOutbox.entryID(fromMessageID: "user-9"))
    }

    /// Entries leave one-by-one as they send; a refused entry stops the drain and
    /// stays, marked failed, while the refusal never touches other chats.
    func testDrainStopsAtFailureAndMarksFailed() throws {
        let outbox = makeOutbox()
        let chatKey = TextMessageOutbox.chatKey(for: keyA)
        outbox.add(TextOutboxEntry(id: "first", chatKey: chatKey, text: "first", createdAt: .init(timeIntervalSince1970: 1)))
        outbox.add(TextOutboxEntry(id: "second", chatKey: chatKey, text: "second", createdAt: .init(timeIntervalSince1970: 2)))
        outbox.add(TextOutboxEntry(id: "third", chatKey: chatKey, text: " pending-after-failure".trimmingCharacters(in: .whitespaces), createdAt: .init(timeIntervalSince1970: 3)))

        // Simulate the drain: first sends, second refused.
        var first = outbox.entry(id: "first")!
        first.attempts += 1
        outbox.remove(id: "first")
        var second = outbox.entry(id: "second")!
        second.attempts += 1
        second.failed = true
        outbox.update(second)

        XCTAssertEqual(outbox.entries(for: chatKey).map(\.id), ["second", "third"])
        XCTAssertEqual(outbox.entry(id: "second")?.failed, true)
        XCTAssertEqual(outbox.entry(id: "second")?.attempts, 1)
        // The failed row keeps the pending display kind the transcript keys off.
        XCTAssertEqual(TextMessageOutbox.pendingMessage(for: outbox.entry(id: "second")!).displayKind,
                       TextMessageOutbox.pendingFailedDisplayKind)

        // Retry clears failed and the next drain picks it up again, oldest first.
        var retried = outbox.entry(id: "second")!
        retried.failed = false
        outbox.update(retried)
        XCTAssertFalse(outbox.entry(id: "second")!.failed)
        XCTAssertEqual(outbox.entries(for: chatKey).map(\.id), ["second", "third"])
    }

    /// The `.new → session` key move carries the chat's queued prompts with it, as
    /// `hermesDraftKeyDidChange` does when the host names the session.
    func testDraftKeyMoveCarriesQueuedPrompts() throws {
        let outbox = makeOutbox()
        let from = TextMessageOutbox.chatKey(for: keyA)
        let to = TextMessageOutbox.chatKey(for: ChatDraftKey.hermesSession(server: server, connectionID: UUID(), profile: "default", key: "named"))
        outbox.add(TextOutboxEntry(id: "e1", chatKey: from, text: "Ping", createdAt: .init(timeIntervalSince1970: 1)))
        outbox.move(from: from, to: to)
        XCTAssertTrue(outbox.entries(for: from).isEmpty)
        XCTAssertEqual(outbox.entries(for: to).map(\.text), ["Ping"])
    }

    /// Offline-born chats persist in the registry: a relaunch or the session list
    /// sees the same chat, and it leaves once nothing of it is left to send.
    func testLocalPendingChatRegistryLifecycle() throws {
        let registry = makeRegistry()
        let chatKey = TextMessageOutbox.chatKey(for: keyA)
        let chat = LocalPendingChat(id: "chat1", chatKey: keyA, profile: "default", cwd: "/tmp", createdAt: .init(timeIntervalSince1970: 1))
        registry.add(chat)

        XCTAssertEqual(registry.all().map(\.id), ["chat1"])
        XCTAssertEqual(registry.chat(for: TextMessageOutbox.chatKey(for: keyA))?.id, "chat1")

        // Persistence across a fresh instance.
        let relaunched = makeRegistry()
        XCTAssertEqual(relaunched.all().map(\.id), ["chat1"])

        // Drained: the chat leaves the registry.
        registry.remove(id: "chat1")
        XCTAssertTrue(registry.all().isEmpty)
        XCTAssertNil(registry.chat(for: chatKey))
    }

    /// The outbox file's shape is tolerant: an entry whose fields this build no longer
    /// knows is dropped alone, never the whole queue.
    func testCorruptEntryIsDroppedAlone() throws {
        let outbox = makeOutbox()
        outbox.add(TextOutboxEntry(id: "good", chatKey: TextMessageOutbox.chatKey(for: keyA), text: "Keep",
                                   createdAt: .init(timeIntervalSince1970: 1)))
        // Hand-write a second record with an unknown chatKey context (old build shape).
        let url = directory.appendingPathComponent("outbox.json")
        var entries = try JSONDecoder().decode([TextOutboxEntry].self, from: Data(contentsOf: url))
        entries.append(entries[0])
        entries[1] = TextOutboxEntry(id: "bad", chatKey: entries[1].chatKey + "-old", text: "Old", createdAt: .init(timeIntervalSince1970: 2))
        try JSONEncoder().encode(entries).write(to: url)

        let relaunched = makeOutbox()
        XCTAssertEqual(relaunched.entries(for: TextMessageOutbox.chatKey(for: keyA)).map(\.id), ["good"])
        // The malformed chatKey simply lands in another bucket, never crashes.
        XCTAssertEqual(relaunched.entries(for: entries[1].chatKey).map(\.id), ["bad"])
    }
}
