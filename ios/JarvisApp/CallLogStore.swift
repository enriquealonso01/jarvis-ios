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
        /// Audio verification line, set only from a REAL gateway summary
        /// received over the data channel at session stop (in/out frame
        /// counts). nil = never received (older builds, crashed sessions) —
        /// the UI must NOT invent a quality line when this is nil.
        var audioInFrames: Int?
        var audioOutFrames: Int?
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

    /// Injectable storage so unit tests run against an ephemeral suite
    /// instead of the shared singleton's persisted log.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
            Self.reapStale(&entries)
        }
    }

    private let defaults: UserDefaults

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
        let entry = Entry(id: id, reason: reason, at: at, outgoing: outgoing,
                          outcome: nil, durationSeconds: nil,
                          audioInFrames: nil, audioOutFrames: nil)
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
        stamp(id: id, outcome: outcome, durationSeconds: durationSeconds,
              audio: nil)
    }

    /// Audio-quality stamp from the gateway's session-stop summary relayed
    /// over the data channel: {type:"audio_summary", audio_in_frames, audio_out_frames}.
    /// Called SEPARATELY from finish() because the gateway sends the summary
    /// just BEFORE the peerLeft signalling — the entry may still be open when
    /// the numbers arrive. Nothing is stamped on a missing entry (id:nil
    /// fallback only touches fresh open entries, same contract as finish()).
    func stampAudioSummary(id: String? = nil, inFrames: Int, outFrames: Int) {
        stamp(id: id, outcome: nil, durationSeconds: nil,
              audio: (inFrames, outFrames))
    }

    private func stamp(id: String?, outcome: String?, durationSeconds: Int?,
                       audio: (Int, Int)?) {
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
        if let outcome {
            entries[idx].outcome = outcome
        }
        if let durationSeconds {
            entries[idx].durationSeconds = durationSeconds
        }
        if let audio {
            entries[idx].audioInFrames = audio.0
            entries[idx].audioOutFrames = audio.1
        }
        persist()
    }

    /// Pure formatter for the log row's quality line (unit-tested): the
    /// semantics come from the gateway's own summary note — in>0 = mic capture
    /// proven, out>0 = bot audio sent. Returns nil when no summary arrived
    /// (the row simply shows no quality line — never a guess).
    /// nonisolated: pure function of its arguments, so tests can call it
    /// from a synchronous nonisolated context (Swift 6 actor isolation).
    nonisolated static func audioQualityLabel(inFrames: Int?, outFrames: Int?) -> String? {
        guard let inF = inFrames, let outF = outFrames else { return nil }
        switch (inF > 0, outF > 0) {
        case (true, true): return "audio in/out confirmed"
        case (true, false): return "audio in only — no bot audio sent"
        case (false, true): return "audio out only — mic never captured"
        case (false, false): return "no audio either way"
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
