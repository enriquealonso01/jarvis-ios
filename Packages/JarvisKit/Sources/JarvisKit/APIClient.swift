import Foundation
import Persistence

/// API client actor (plan §5.1). All network I/O lives here; Sendable struct
/// snapshots cross isolation boundaries. Grows in Items 1–2: message send
/// (outbox-enqueued when offline) + SSE stream endpoint per the fixture
/// contract (JarvisKit/Fixtures/contract.json).
/// Supplies the current dashboard bearer (refreshing it when needed) right
/// before each request. nil = send unauthenticated (tests / fixtures).
public typealias BearerProvider = @Sendable () async -> String?

public actor APIClient {
    private let config: ServerConfig
    private var token: String?
    private let session: URLSession
    private let bearerProvider: BearerProvider?

    public init(config: ServerConfig, token: String? = nil, session: URLSession = .shared,
                bearerProvider: BearerProvider? = nil) {
        self.config = config
        self.token = token
        self.session = session
        self.bearerProvider = bearerProvider
    }

    public func setToken(_ newToken: String?) { token = newToken }

    // MARK: - Item 2: message send + event stream (fixture contract)

    /// POST a message. When `online` is false (or the request fails with a
    /// transport error) the returned payload is what the caller converts to
    /// an `OutboxEntry` (Persistence) — offline-first (feature #4): the send
    /// is never lost, it replays with backoff when connectivity returns.
    /// - Returns: the replayable send payload (JarvisKit-owned mirror of the
    ///   outbox wire format — this package must not depend on Persistence),
    ///   plus the server reply when the POST actually went through.
    @discardableResult
    public func postMessage(conversationID: UUID,
                            messageID: UUID,
                            body: String,
                            online: Bool = true) async throws -> (payload: OutboxSendPayload, reply: MessageSendReply?) {
        let payload = OutboxSendPayload(kind: OutboxSendPayload.sendKind,
                                        conversationID: conversationID,
                                        messageID: messageID,
                                        body: body)
        guard online else { return (payload, nil) }
        do {
            let reply: MessageSendReply? = try await post(
                path: Self.messageEndpoint(conversationID),
                body: ["message_id": messageID.uuidString, "content": body],
                as: Optional<MessageSendReply>.self
            )
            return (payload, reply)
        } catch APIError.transportError {
            // Connection-level failure → replayable (caller enqueues payload).
            return (payload, nil)
        }
    }

    /// POST /v1/conversations/{id}/messages (fixture contract).
    public nonisolated static func messageEndpoint(_ conversationID: UUID) -> String {
        "/v1/conversations/\(conversationID.uuidString)/messages"
    }

    /// GET the conversation's SSE event stream (fixture contract:
    /// JarvisKit/Fixtures/contract.json). Events flow through `SSEClient`.
    public nonisolated func streamPath(conversationID: UUID) -> String {
        SSEClient.streamEndpoint(conversationID)
    }

    // MARK: - Core HTTP

    /// GET an endpoint, returning decoded JSON. Never force-unwraps URLs.
    public func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        await refreshBearer()
        let request = try makeRequest(path: path, method: "GET")
        let data = try await send(request)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// POST a JSON body, returning the decoded response. Pass
    /// `Optional<D>.self` for endpoints that answer 204/empty.
    public func post<Body: Encodable, D: Decodable>(path: String,
                                                    body: Body,
                                                    as type: Optional<D>.Type) async throws -> D? {
        let data = try await postData(path: path, body: body)
        if data.isEmpty { return nil }
        return try JSONDecoder().decode(D.self, from: data)
    }

    /// POST a JSON body, returning the decoded response.
    public func post<Body: Encodable, T: Decodable>(path: String,
                                                    body: Body,
                                                    as type: T.Type) async throws -> T {
        let data = try await postData(path: path, body: body)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// POST a JSON body, discarding the (possibly empty) response.
    public func post<Body: Encodable>(path: String, body: Body) async throws {
        _ = try await postData(path: path, body: body)
    }

    // MARK: Internals

    /// Pull a fresh bearer from the provider (when one is wired).
    private func refreshBearer() async {
        guard let bearerProvider else { return }
        if let fresh = await bearerProvider() { token = fresh }
    }

    private func postData<Body: Encodable>(path: String, body: Body) async throws -> Data {
        await refreshBearer()
        var request = try makeRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await send(request)
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        guard let url = config.url(path) else { throw APIError.badURL(path) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: request)
        } catch {
            // URLSession surface errors (offline, DNS, TLS) map to one
            // replayable case so the outbox path can catch precisely.
            throw APIError.transportError
        }
        guard let http = resp as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.badStatus(http.statusCode)
        }
        return data
    }
}

public enum APIError: Error, Equatable, Sendable {
    case badURL(String)
    case badStatus(Int)
    case badResponse
    /// Unreachable transport (offline / DNS / TLS) — safe to replay via the
    /// outbox with backoff.
    case transportError
}

/// JarvisKit-owned mirror of the outbox send payload (wire format of
/// `OutboxEntry.payload`). Lives here because JarvisKit must not depend on
/// Persistence; keys match Persistence.OutboxPayload exactly (the outbox is
/// the single source of truth for offline sends, feature #4).
public struct OutboxSendPayload: Sendable, Equatable, Codable {
    /// Same tag as `Persistence.OutboxPayload.sendKind` — one replay path.
    public static let sendKind = "send-message"

    public var kind: String
    public var conversationID: UUID?
    public var messageID: UUID?
    public var body: String

    public init(kind: String, conversationID: UUID? = nil,
                messageID: UUID? = nil, body: String = "") {
        self.kind = kind
        self.conversationID = conversationID
        self.messageID = messageID
        self.body = body
    }
}

/// POST /v1/conversations/{id}/messages reply (fixture contract). All fields
/// optional so an empty 204 body decodes as `.none` via `Optional<T>.self`.
public struct MessageSendReply: Sendable, Equatable, Codable {
    public var messageID: String?
    public var conversationID: String?
    public var accepted: Bool?

    public init(messageID: String? = nil, conversationID: String? = nil, accepted: Bool? = nil) {
        self.messageID = messageID
        self.conversationID = conversationID
        self.accepted = accepted
    }

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case conversationID = "conversation_id"
        case accepted
    }
}
