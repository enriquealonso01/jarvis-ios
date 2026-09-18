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
    /// Entries still OPEN (outcome == nil) older than this never got their
    /// outcome stamp: "Ring this phone" queues the push SERVER-SIDE until the
    /// APNs p8 is installed (no ring → no end → no stamp), a bridge failure
    /// never wakes the app, or a hard kill during a call skips the end path.
    /// Every such zombie poisons the log (a red "missed" row that never
    /// happened) — and worse, `finish(id:nil)`'s "latest open entry" fallback
    /// can mis-stamp a LATER call's outcome onto it.
    private static let openTTL: TimeInterval = 6 * 3600

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
            Self.reapStale(&entries)
        }
    }

    /// Close-out entries that have been open too long, in place.
    private static func reapStale(_ list: inout [Entry]) {
        let cutoff = Date().addingTimeInterval(-openTTL)
        var reaped = false
        for i in list.indices where list[i].outcome == nil && list[i].at < cutoff {
            list[i].outcome = "missed"
            reaped = true
        }
        _ = reaped
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
        // Stale zombies never receive a real outcome (queued push, kill during
        // a call); don't let an id:nil fallback stamp one of THOSE.
        let target: Int?
        if let id, let idx = entries.lastIndex(where: { $0.id == id }) {
            target = idx
        } else {
            let freshEnough = Date().addingTimeInterval(-Self.openTTL)
            target = entries.lastIndex { $0.outcome == nil && $0.at > freshEnough }
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
