import Foundation

/// A typed message on its way to JARVIS (offline-first): the text sits in its
/// chat's transcript the moment Send is pressed, with or without a connection,
/// as a pending bubble with a clock. It goes out when the chat connects, in
/// order, and the entry leaves once the host has the prompt. Kept across
/// launches in Application Support, beside the voice-note outbox it mirrors.
struct TextOutboxEntry: Codable, Equatable, Identifiable, Sendable {
    let id: String
    /// The chat it belongs to (`TextMessageOutbox.chatKey(for:)`).
    var chatKey: String
    let text: String
    let createdAt: Date
    var attempts = 0
    /// The last drain tried and the host or network refused it: the bubble's
    /// clock becomes a red exclamation with Retry and Delete.
    var failed = false

    var messageID: String { TextMessageOutbox.messageID(for: id) }
}

/// The pending rows and the outbox queue for typed messages, mirroring
/// `VoiceNoteOutbox`. The chat itself exists at once offline as a
/// `LocalPendingChat`, so the session list shows it before any network.
final class TextMessageOutbox: @unchecked Sendable {
    static let shared = TextMessageOutbox()

    /// A pending row's id carries this prefix; the row is this phone's own.
    static let pendingMessagePrefix = "text-pending-"

    static func messageID(for entryID: String) -> String { pendingMessagePrefix + entryID }

    static func entryID(fromMessageID messageID: String?) -> String? {
        guard let messageID, messageID.hasPrefix(pendingMessagePrefix) else { return nil }
        return String(messageID.dropFirst(pendingMessagePrefix.count))
    }

    /// One chat's key, the same shape as `VoiceNoteOutbox.chatKey(for:)`.
    static func chatKey(for key: ChatDraftKey) -> String {
        "\(key.serverID)|\(String(describing: key.context))"
    }

    /// Display-only marker rows carry in `ChatMessage.displayKind`: a queued
    /// text row, and the same row once a drain's send was refused.
    static let pendingDisplayKind = "queued-text"
    static let pendingFailedDisplayKind = "queued-text-failed"

    /// The chat row a pending message shows: the sent text, as a user row.
    /// The display kind carries the row's status so a failed drain re-renders
    /// the row (the message text alone does not change).
    static func pendingMessage(for entry: TextOutboxEntry) -> ChatMessage {
        ChatMessage(role: "user", content: entry.text, timestamp: entry.createdAt.timeIntervalSince1970,
                    messageId: entry.messageID, displayKind: entry.failed ? pendingFailedDisplayKind : pendingDisplayKind)
    }

    private let url: URL
    private let lock = NSLock()
    private var loaded: [TextOutboxEntry]?

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JarvisVoiceNotes", isDirectory: true).appendingPathComponent("text-outbox.json")
    }

    private func entries() -> [TextOutboxEntry] {
        if let loaded { return loaded }
        let read = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([TextOutboxEntry].self, from: $0) } ?? []
        loaded = read
        return read
    }

    private func write(_ entries: [TextOutboxEntry]) {
        loaded = entries
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }

    /// The chat's pending messages, oldest first.
    func entries(for chatKey: String) -> [TextOutboxEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries().filter { $0.chatKey == chatKey }.sorted { $0.createdAt < $1.createdAt }
    }

    /// One entry by its id, for the row that shows it.
    func entry(id: String) -> TextOutboxEntry? {
        lock.lock(); defer { lock.unlock() }
        return entries().first { $0.id == id }
    }

    /// Every chat key with pending messages, for the session list's badges.
    func chatKeysWithEntries() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(entries().map(\.chatKey))
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return entries().isEmpty
    }

    func add(_ entry: TextOutboxEntry) {
        lock.lock(); defer { lock.unlock() }
        write(entries().filter { $0.id != entry.id } + [entry])
    }

    func update(_ entry: TextOutboxEntry) {
        lock.lock(); defer { lock.unlock() }
        write(entries().map { $0.id == entry.id ? entry : $0 })
    }

    func remove(id: String) {
        lock.lock(); defer { lock.unlock() }
        write(entries().filter { $0.id != id })
    }

    /// A new chat got its session: its messages follow the draft key.
    func move(from: String, to: String) {
        lock.lock(); defer { lock.unlock() }
        guard from != to else { return }
        write(entries().map { entry in
            var moved = entry
            if moved.chatKey == from { moved.chatKey = to }
            return moved
        })
    }

    /// For tests.
    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        write([])
    }
}

/// What the user asks of a pending message's failed row.
enum PendingTextAction: Sendable {
    case retry
    case delete
}

/// A chat born on this phone with no network (offline-first): Send in an
/// unattached new chat creates one of these at once — a real draft key, the
/// first message in the text outbox — so the chat exists in the session list
/// the moment its message is typed, not when the host finally answers. The
/// first successful drain turns it into the host's session, whose own draft
/// key and list row take over; the record here goes then.
struct LocalPendingChat: Codable, Equatable, Identifiable, Sendable {
    let id: String
    /// The draft key the chat holds: `hermesSession(key: nil)` on its Profile.
    let chatKey: ChatDraftKey
    let profile: String
    let cwd: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey { case id, chatKey, profile, cwd, createdAt }

    init(id: String, chatKey: ChatDraftKey, profile: String, cwd: String?, createdAt: Date) {
        self.id = id
        self.chatKey = chatKey
        self.profile = profile
        self.cwd = cwd
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        // Tolerant: a chat key saved by another shape of build is dropped by
        // the registry's per-record decode, not by the whole file.
        guard let key = try container.decode(DraftKeyRecord.self, forKey: .chatKey).key else {
            throw DecodingError.dataCorruptedError(forKey: .chatKey, in: container, debugDescription: "unreadable chat key")
        }
        chatKey = key
        profile = try container.decode(String.self, forKey: .profile)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(DraftKeyRecord(key: chatKey), forKey: .chatKey)
        try container.encode(profile, forKey: .profile)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encode(createdAt, forKey: .createdAt)
    }

    /// The wire form of a `ChatDraftKey`, tolerant both ways: a server id, and
    /// a context that names its shape so an unknown one decodes as nil.
    private struct DraftKeyRecord: Codable {
        let serverID: String?
        let context: ContextRecord?

        enum CodingKeys: String, CodingKey { case serverID, context }

        init(key: ChatDraftKey) {
            serverID = key.serverID
            context = ContextRecord(key.context)
        }

        var key: ChatDraftKey? {
            guard let serverID, let context else { return nil }
            return ChatDraftKey(serverID: serverID, context: context.context)
        }
    }

    private enum ContextRecord: Codable {
        case session(String)
        case bot(connectionID: UUID, profile: String)
        case hermesSession(connectionID: UUID, profile: String, key: String?)
        case newChat
        case unknown

        enum CodingKeys: String, CodingKey {
            case kind, sessionID, connectionID, profile, key
        }

        init(_ context: ChatDraftKey.Context) {
            switch context {
            case .session(let id): self = .session(id)
            case .bot(let connectionID, let profile): self = .bot(connectionID: connectionID, profile: profile)
            case .hermesSession(let connectionID, let profile, let key):
                self = .hermesSession(connectionID: connectionID, profile: profile, key: key)
            case .newChat: self = .newChat
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .kind) {
            case "session": self = .session(try container.decode(String.self, forKey: .sessionID))
            case "bot":
                self = .bot(connectionID: try container.decode(UUID.self, forKey: .connectionID),
                            profile: try container.decode(String.self, forKey: .profile))
            case "hermesSession":
                self = .hermesSession(connectionID: try container.decode(UUID.self, forKey: .connectionID),
                                      profile: try container.decode(String.self, forKey: .profile),
                                      key: try container.decodeIfPresent(String.self, forKey: .key))
            case "newChat": self = .newChat
            default: self = .unknown
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .session(let id):
                try container.encode("session", forKey: .kind)
                try container.encode(id, forKey: .sessionID)
            case .bot(let connectionID, let profile):
                try container.encode("bot", forKey: .kind)
                try container.encode(connectionID, forKey: .connectionID)
                try container.encode(profile, forKey: .profile)
            case .hermesSession(let connectionID, let profile, let key):
                try container.encode("hermesSession", forKey: .kind)
                try container.encode(connectionID, forKey: .connectionID)
                try container.encode(profile, forKey: .profile)
                try container.encodeIfPresent(key, forKey: .key)
            case .newChat:
                try container.encode("newChat", forKey: .kind)
            case .unknown:
                try container.encode("unknown", forKey: .kind)
            }
        }

        var context: ChatDraftKey.Context {
            switch self {
            case .session(let id): return .session(id)
            case .bot(let connectionID, let profile): return .bot(connectionID: connectionID, profile: profile)
            case .hermesSession(let connectionID, let profile, let key):
                return .hermesSession(connectionID: connectionID, profile: profile, key: key)
            case .newChat: return .newChat
            case .unknown: return .newChat
            }
        }
    }
}

/// The phone's offline-born chats, newest first, kept beside the outbox in
/// Application Support. Records leave once their chat attaches and its
/// messages drain; one whose messages were all deleted leaves too.
final class LocalPendingChatRegistry: @unchecked Sendable {
    static let shared = LocalPendingChatRegistry()

    private let url: URL
    private let lock = NSLock()
    private var loaded: [LocalPendingChat]?

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JarvisVoiceNotes", isDirectory: true).appendingPathComponent("local-chats.json")
    }

    private func chats() -> [LocalPendingChat] {
        if let loaded { return loaded }
        // Per-record tolerance: one chat whose key shape this build no longer
        // knows is dropped alone, never the rest of the file.
        let read = (try? Data(contentsOf: url)).flatMap { data in
            (try? JSONDecoder().decode([FailableRecord].self, from: data))?.compactMap(\.value)
        } ?? []
        loaded = read
        return read
    }

    private struct FailableRecord: Codable {
        let value: LocalPendingChat?

        init(value: LocalPendingChat?) {
            self.value = value
        }

        init(from decoder: Decoder) throws {
            value = try? LocalPendingChat(from: decoder)
        }

        func encode(to encoder: Encoder) throws {
            guard let value else { return }
            try value.encode(to: encoder)
        }
    }

    private func write(_ chats: [LocalPendingChat]) {
        loaded = chats
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(chats.map(FailableRecord.init(value:))) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// All offline-born chats, newest first.
    func all() -> [LocalPendingChat] {
        lock.lock(); defer { lock.unlock() }
        return chats().sorted { $0.createdAt > $1.createdAt }
    }

    /// The offline-born chat holding this draft key, if any.
    func chat(for chatKey: String) -> LocalPendingChat? {
        lock.lock(); defer { lock.unlock() }
        return chats().first { TextMessageOutbox.chatKey(for: $0.chatKey) == chatKey }
    }

    func add(_ chat: LocalPendingChat) {
        lock.lock(); defer { lock.unlock() }
        write((chats().filter { $0.id != chat.id } + [chat]))
    }

    func remove(id: String) {
        lock.lock(); defer { lock.unlock() }
        write(chats().filter { $0.id != id })
    }

    /// For tests.
    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        write([])
    }
}
