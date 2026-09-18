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
    }

    @Published private(set) var entries: [Entry] = []

    private static let key = "jarvis.calllog.v1"
    private static let cap = 100

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    func add(reason: String, outgoing: Bool, at: Date = Date()) {
        let entry = Entry(id: UUID().uuidString, reason: reason, at: at, outgoing: outgoing)
        entries.append(entry)
        if entries.count > Self.cap {
            entries.removeFirst(entries.count - Self.cap)
        }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
