import Foundation

/// Server identity: where the Hermes backend lives.
public struct ServerConfig: Sendable, Equatable, Codable {
    public var baseURL: URL

    public init(baseURL: URL) { self.baseURL = baseURL }

    /// Build an endpoint URL or nil if malformed — never force-unwrap.
    public func url(_ path: String) -> URL? {
        URL(string: path, relativeTo: baseURL)?.absoluteURL
    }
}

/// A chat conversation (v2 model, per V2-PLAN §5.2).
public struct Conversation: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var serverID: String?
    public var title: String
    public var projectID: UUID?
    public var createdAt: Date
    public var pendingSync: Bool

    public init(id: UUID = UUID(), serverID: String? = nil, title: String,
                projectID: UUID? = nil, createdAt: Date = Date(), pendingSync: Bool = false) {
        self.id = id
        self.serverID = serverID
        self.title = title
        self.projectID = projectID
        self.createdAt = createdAt
        self.pendingSync = pendingSync
    }
}

/// Roles for chat messages.
public enum MessageRole: String, Sendable, Codable {
    case user, assistant, system
}

/// A chat message (v2 model). Local UUID is the source of truth; `serverID`
/// links to the backend copy; `branchID`/`branchIndex` support branching (UI Law §4).
public struct Message: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var serverID: String?
    public var conversationID: UUID
    public var role: MessageRole
    public var text: String
    public var createdAt: Date
    public var pendingSync: Bool
    public var branchID: UUID?
    public var branchIndex: Int

    public init(id: UUID = UUID(), serverID: String? = nil, conversationID: UUID,
                role: MessageRole, text: String, createdAt: Date = Date(),
                pendingSync: Bool = false, branchID: UUID? = nil, branchIndex: Int = 0) {
        self.id = id
        self.serverID = serverID
        self.conversationID = conversationID
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.pendingSync = pendingSync
        self.branchID = branchID
        self.branchIndex = branchIndex
    }
}

/// Unified SSE/WS agent event envelope (plan §5.3 — schema lives contract-first).
public struct AgentEvent: Sendable, Equatable, Identifiable, Codable {
    public var id: Int64
    public var kind: String
    public var payload: String

    public init(id: Int64, kind: String, payload: String) {
        self.id = id
        self.kind = kind
        self.payload = payload
    }
}
