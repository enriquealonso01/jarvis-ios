import Foundation
import JarvisKit
import Persistence

/// Outbound send path (feature #1 + #4): POST the user message; when offline
/// (or the transport fails), enqueue an outbox entry so the send replays
/// with backoff on reconnect — never lost. Actor-isolated.
public actor MessageSendCoordinator {
    private let api: APIClient
    private let store: PersistenceStore
    private let outbox: OutboxActor

    public init(api: APIClient, store: PersistenceStore,
                transport: OutboxSend? = nil) {
        self.api = api
        self.store = store
        if let transport {
            self.outbox = OutboxActor(store: store, send: transport)
        } else {
            self.outbox = OutboxActor(store: store, send: Self.defaultTransport(api))
        }
    }

    /// Persist + attempt delivery. Returns the stored user message row.
    @discardableResult
    public func send(conversationID: UUID,
                     text: String,
                     online: Bool = true,
                     now: Date = Date()) async throws -> StoredMessage {
        // Local-first: the user bubble exists even with no network.
        var userMessage = StoredMessage(
            conversationID: conversationID,
            role: .user,
            content: text,
            status: .sending,
            createdAt: now
        )
        userMessage.status = online ? .sent : .failed
        await store.upsert(userMessage)

        do {
            let result = try await api.postMessage(conversationID: conversationID,
                                                   messageID: userMessage.id,
                                                   body: text,
                                                   online: online)
            if result.reply == nil {
                // Offline / unreachable: enqueue for replay (backoff on drain).
                await store.enqueue(OutboxEntry(payload: OutboxPayload(
                    kind: result.payload.kind,
                    conversationID: result.payload.conversationID,
                    messageID: result.payload.messageID,
                    body: result.payload.body
                )))
            }
        } catch {
            // ANY delivery failure (HTTP status, decoding, transport) still
            // enqueues — the outbox, not the error path, owns durability.
            let payload = OutboxPayload(kind: OutboxPayload.sendKind,
                                        conversationID: conversationID,
                                        messageID: userMessage.id,
                                        body: text)
            await store.enqueue(OutboxEntry(payload: payload))
        }
        return userMessage
    }

    /// Deliver a user row the composer ALREADY wrote (no second row): POST it
    /// under its own id, mark it sent, or enqueue it for replay + mark failed.
    /// A successful delivery also drains anything queued earlier.
    public func deliver(_ message: StoredMessage) async {
        var row = message
        do {
            let result = try await api.postMessage(conversationID: row.conversationID,
                                                   messageID: row.id,
                                                   body: row.content,
                                                   online: true)
            if result.reply == nil {
                await store.enqueue(OutboxEntry(payload: OutboxPayload(
                    kind: result.payload.kind,
                    conversationID: result.payload.conversationID,
                    messageID: result.payload.messageID,
                    body: result.payload.body
                )))
                row.status = .failed
            } else {
                row.status = .sent
            }
        } catch {
            await store.enqueue(OutboxEntry(payload: OutboxPayload(
                kind: OutboxPayload.sendKind,
                conversationID: row.conversationID,
                messageID: row.id,
                body: row.content)))
            row.status = .failed
        }
        await store.upsert(row)
        if row.status == .sent {
            _ = try? await outbox.drainOnce()
        }
    }

    /// Drain the outbox now (call on reconnect / app active).
    @discardableResult
    public func drainOutbox() async throws -> Int {
        try await outbox.drainOnce()
    }

    /// The production replay transport: a `send-message` payload POSTs to
    /// the same endpoint as the live path.
    private static func defaultTransport(_ api: APIClient) -> OutboxSend {
        { entry in
            guard entry.payload.kind == OutboxPayload.sendKind else { return }
            struct SendBody: Encodable {
                var message_id: String
                var content: String
            }
            if let conversationID = entry.payload.conversationID {
                let _: MessageSendReply? = try await api.post(
                    path: APIClient.messageEndpoint(conversationID),
                    body: SendBody(message_id: entry.payload.messageID?.uuidString ?? entry.id.uuidString,
                                   content: entry.payload.body),
                    as: Optional<MessageSendReply>.self
                )
            }
        }
    }
}
