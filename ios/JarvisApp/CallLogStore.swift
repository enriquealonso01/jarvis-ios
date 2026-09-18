import Foundation

/// Persistent call log (backlog #4 polish). Entries survive app restarts and
/// are written from BOTH directions:
///   - incoming: CallManager.handleVoIPPayload (PushKit wakes the app even
///     killed/locked — a quick UserDefaults write fits the background budget)
///   - outgoing: CallsView "Call me"
/// Previously the log was `@State` in CallsView only: it reset on every
/// restart and incoming calls never appeared at all.
@MainActor
final class CallLogStore: ObservableObject {
    static let shared = CallLogStore()

    struct Entry: Codable, Identifiable {
        let id: String
        let reason: String
        let at: Date
        let outgoing: Bool
        /// "ended", "missed", "failed: …", or nil while still ringing/active.
        var outcome: String?
        var durationSeconds: Int?
    }

    @Published private(set) var entries: [Entry] = []

    private static let key = "jarvis.calllog.v2"
    private static let cap = 100

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    func add(reason: String, outgoing: Bool, at: Date = Date()) -> String {
        let id = UUID().uuidString
        let entry = Entry(id: id, reason: reason, at: at, outgoing: outgoing, outcome: nil, durationSeconds: nil)
        entries.append(entry)
        if entries.count > Self.cap {
            entries.removeFirst(entries.count - Self.cap)
        }
        persist()
        return id
    }

    /// Stamp the outcome on the entry whose lifecycle just closed (by exact id,
    /// or latest matching open entry when the id isn't known — e.g. a push
    /// wake that never surfaced the CallKit end action to us).
    func finish(id: String? = nil, outcome: String, durationSeconds: Int? = nil) {
        let target: Int?
        if let id, let idx = entries.lastIndex(where: { $0.id == id }) {
            target = idx
        } else {
            target = entries.lastIndex { $0.outcome == nil }
        }
        guard let idx = target else { return }
        entries[idx].outcome = outcome
        entries[idx].durationSeconds = durationSeconds
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
