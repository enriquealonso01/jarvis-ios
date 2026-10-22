import CryptoKit
import Foundation

/// How a JARVIS voice note reads in the session: the transcript after a microphone marker, so
/// JARVIS knows it was spoken. The agent gets only this text, never the audio (Enrique's rule,
/// 2026-10-21: transcribe once on Send; no `@file`, no attachment, no second transcription).
enum VoiceNoteText {
    static let marker = "🎤 "

    /// The user's message for a transcript.
    static func message(transcript: String) -> String {
        marker + transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isVoiceNote(_ content: String?) -> Bool {
        guard let content else { return false }
        return content.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(marker.trimmingCharacters(in: .whitespaces))
    }

    /// The transcript inside a voice note's message.
    static func transcript(from content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = marker.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(bare) else { return trimmed }
        return String(trimmed.dropFirst(bare.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Voice notes' audio, kept on this phone only: the host never receives the clip, so the chat's
/// audio bubble plays it from here. A clip is stored by its own id the moment it is recorded
/// (before any transcript exists) and, once sent, found again by the message's text. Another
/// device (or a reinstall) shows the transcript without audio. Keeps the newest `limit` clips.
final class VoiceNoteLocalStore: @unchecked Sendable {
    static let shared = VoiceNoteLocalStore()
    static let limit = 300

    let directory: URL
    private let lock = NSLock()

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JarvisVoiceNotes", isDirectory: true)
    }

    static func key(forMessageText text: String) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: By clip id

    private func clipURL(id: String) -> URL { directory.appendingPathComponent(id + ".m4a") }
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    /// Stores a clip under its own id (a pending note's, or a text key).
    func save(_ audio: Data, id: String) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? audio.write(to: clipURL(id: id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        prune()
    }

    func audio(forID id: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return try? Data(contentsOf: clipURL(id: id))
    }

    func hasAudio(forID id: String) -> Bool {
        FileManager.default.fileExists(atPath: clipURL(id: id).path)
    }

    func remove(id: String) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: clipURL(id: id))
    }

    /// Once the note's message text is known: the bubble finds the clip by that text.
    func link(messageText: String, toID id: String) {
        lock.lock(); defer { lock.unlock() }
        var index = loadIndex()
        index[Self.key(forMessageText: messageText)] = id
        saveIndex(index)
    }

    private func loadIndex() -> [String: String] {
        guard let data = try? Data(contentsOf: indexURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func saveIndex(_ index: [String: String]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
    }

    // MARK: By message

    /// The clip id a message's text maps to: the index first, else the text's own key (clips
    /// build 82 saved straight under it).
    private func clipID(forMessageText text: String) -> String? {
        let key = Self.key(forMessageText: text)
        if let linked = loadIndex()[key], FileManager.default.fileExists(atPath: clipURL(id: linked).path) { return linked }
        return FileManager.default.fileExists(atPath: clipURL(id: key).path) ? key : nil
    }

    func save(_ audio: Data, forMessageText text: String) {
        let id = Self.key(forMessageText: text)
        save(audio, id: id)
        link(messageText: text, toID: id)
    }

    func audio(forMessageText text: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let id = clipID(forMessageText: text) else { return nil }
        return try? Data(contentsOf: clipURL(id: id))
    }

    func hasAudio(forMessageText text: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return clipID(forMessageText: text) != nil
    }

    func remove(forMessageText text: String) {
        lock.lock(); defer { lock.unlock() }
        if let id = clipID(forMessageText: text) { try? FileManager.default.removeItem(at: clipURL(id: id)) }
    }

    /// A chat row's clip: a note still waiting to be sent by its pending id, a sent one by its text.
    func audio(for message: ChatMessage) -> Data? {
        if let id = VoiceNoteOutbox.entryID(fromMessageID: message.messageId) { return audio(forID: id) }
        return audio(forMessageText: message.content ?? "")
    }

    func hasAudio(for message: ChatMessage) -> Bool {
        if let id = VoiceNoteOutbox.entryID(fromMessageID: message.messageId) { return hasAudio(forID: id) }
        return hasAudio(forMessageText: message.content ?? "")
    }

    private func prune() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys),
              case let clips = files.filter({ $0.pathExtension == "m4a" }), clips.count > Self.limit else { return }
        let sorted = clips.sorted {
            let a = (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return a < b
        }
        for file in sorted.prefix(clips.count - Self.limit) { try? FileManager.default.removeItem(at: file) }
    }
}

/// A voice note on its way to JARVIS (offline-first, Enrique 2026-10-22): the clip is on the
/// phone and its bubble in the chat the moment Send is pressed, with or without a connection.
/// Transcription and the text-only prompt follow when the chat is connected, in order, and the
/// entry goes once the host has the prompt. Kept across launches in Application Support.
struct VoiceNoteOutboxEntry: Codable, Equatable, Identifiable, Sendable {
    let id: String
    /// The chat it belongs to (`VoiceNoteOutbox.chatKey(for:)`).
    var chatKey: String
    let filename: String
    let createdAt: Date
    /// Set once transcribed; the send then needs no network for anything but the prompt.
    var transcript: String?
    var attempts = 0

    var messageID: String { VoiceNoteOutbox.messageID(for: id) }
}

final class VoiceNoteOutbox: @unchecked Sendable {
    static let shared = VoiceNoteOutbox()
    /// The chat row of a note not yet sent carries this prefix; the row is this phone's own.
    static let pendingMessagePrefix = "voice-pending-"

    static func messageID(for entryID: String) -> String { pendingMessagePrefix + entryID }

    static func entryID(fromMessageID messageID: String?) -> String? {
        guard let messageID, messageID.hasPrefix(pendingMessagePrefix) else { return nil }
        return String(messageID.dropFirst(pendingMessagePrefix.count))
    }

    /// One chat's key: its server and draft context, stable across launches.
    static func chatKey(for key: ChatDraftKey) -> String {
        "\(key.serverID)|\(String(describing: key.context))"
    }

    /// The chat row a pending note shows: a user row with the marker alone until the
    /// transcript lands, with the note's audio found by the row's id.
    static func pendingMessage(for entry: VoiceNoteOutboxEntry) -> ChatMessage {
        ChatMessage(role: "user", content: entry.transcript.map(VoiceNoteText.message(transcript:)) ?? VoiceNoteText.marker.trimmingCharacters(in: .whitespaces),
                    timestamp: entry.createdAt.timeIntervalSince1970, messageId: entry.messageID)
    }

    private let url: URL
    private let lock = NSLock()
    private var loaded: [VoiceNoteOutboxEntry]?

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JarvisVoiceNotes", isDirectory: true).appendingPathComponent("outbox.json")
    }

    private func entries() -> [VoiceNoteOutboxEntry] {
        if let loaded { return loaded }
        let read = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([VoiceNoteOutboxEntry].self, from: $0) } ?? []
        loaded = read
        return read
    }

    private func write(_ entries: [VoiceNoteOutboxEntry]) {
        loaded = entries
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }

    /// The chat's pending notes, oldest first.
    func entries(for chatKey: String) -> [VoiceNoteOutboxEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries().filter { $0.chatKey == chatKey }.sorted { $0.createdAt < $1.createdAt }
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return entries().isEmpty
    }

    func add(_ entry: VoiceNoteOutboxEntry) {
        lock.lock(); defer { lock.unlock() }
        write(entries().filter { $0.id != entry.id } + [entry])
    }

    func update(_ entry: VoiceNoteOutboxEntry) {
        lock.lock(); defer { lock.unlock() }
        write(entries().map { $0.id == entry.id ? entry : $0 })
    }

    func remove(id: String) {
        lock.lock(); defer { lock.unlock() }
        write(entries().filter { $0.id != id })
    }

    /// A new chat got its session: its notes follow the draft key.
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
