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
/// audio bubble plays it from here, found by the message's text. Another device (or a reinstall)
/// shows the transcript without audio. Keeps the newest `limit` clips.
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

    private func url(forMessageText text: String) -> URL {
        directory.appendingPathComponent(Self.key(forMessageText: text) + ".m4a")
    }

    func save(_ audio: Data, forMessageText text: String) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? audio.write(to: url(forMessageText: text), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        prune()
    }

    func audio(forMessageText text: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return try? Data(contentsOf: url(forMessageText: text))
    }

    func hasAudio(forMessageText text: String) -> Bool {
        FileManager.default.fileExists(atPath: url(forMessageText: text).path)
    }

    func remove(forMessageText text: String) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url(forMessageText: text))
    }

    private func prune() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys),
              files.count > Self.limit else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return a < b
        }
        for file in sorted.prefix(files.count - Self.limit) { try? FileManager.default.removeItem(at: file) }
    }
}
