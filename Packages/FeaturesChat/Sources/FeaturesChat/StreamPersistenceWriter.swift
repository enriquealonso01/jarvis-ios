import Foundation
import JarvisKit
import Persistence

/// Bridges the ChatStreamEngine to the GRDB store (feature #4 + #1).
///
/// Two write classes:
/// - **Streaming deltas** (`.streaming`): every engine commit upserts the
///   FULL prefix immediately (idempotent replace — a cold launch mid-stream
///   loses at most one 60ms commit window, and the restore path re-tails
///   live from the resume point). The 500ms debounce timer re-drains the
///   pending delta as a retry heartbeat (failed-write insurance), not as a
///   first-write gate.
/// - **Final commits**: `done`/`stopped`/`failed` flush through immediately
///   (no debounce), flip the message row to `.sent` (or `.failed`), and
///   update the conversation row's preview + timestamp (handled by the store
///   layer's `applyStreamDelta`/`finalizeStreamedMessage`).
///
/// Pure scheduling logic with injected persistence calls — unit-testable
/// without GRDB, and the injected closure is what the app wires to the store.
public struct StreamPersistenceWriter {
    /// Debounce window for streaming writes (task spec: 500ms).
    public static let debounceInterval: Double = 0.500

    /// One persistence write (delta upsert / final commit). Injected so tests
    /// can record calls instead of touching a store.
    public typealias Persist = @Sendable (StoredMessage) async -> Void

    /// One planned write: the row to persist + the wall-clock instant of the
    /// snapshot that produced it. `lastEventID` is the stream resume pointer
    /// to persist alongside (0 = none).
    public struct Call: Sendable, Equatable {
        public var message: StoredMessage
        public var lastEventID: Int64
        public var at: Double
        public init(message: StoredMessage, lastEventID: Int64 = 0, at: Double) {
            self.message = message
            self.lastEventID = lastEventID
            self.at = at
        }
    }

    /// What a `record`/`flush` call wants the owner to do: run these writes
    /// now, and (when set) schedule the next debounce flush.
    public struct Plan: Sendable, Equatable {
        public var writes: [Call]
        /// When non-nil: schedule a flush at this instant (500ms debounce).
        public var scheduleNextFlushAt: Double?

        public init(writes: [Call], scheduleNextFlushAt: Double? = nil) {
            self.writes = writes
            self.scheduleNextFlushAt = scheduleNextFlushAt
        }
    }

    /// Debounced (not yet flushed) streaming writes, by stream message id.
    public private(set) var pending: [Int64: Call] = [:]
    private var lastFlushAt: Double = -Double.infinity
    /// Latest instant the caller reported via `now` (wall-clock anchor).
    private var lastKnownNow: Double = 0

    public init() {}

    // MARK: Classification

    /// Is this snapshot terminal (flush-through, never debounced)?
    public static func isFinal(_ phase: ChatMessageStreamPhase) -> Bool {
        switch phase {
        case .done, .failed, .stopped: return true
        case .pending, .streaming: return false
        }
    }

    /// Stream phase → stored message status (task-spec mapping). `stopped`
    /// freezes partial content as `sent` — stop never loses committed text
    /// (UI Law §3).
    public static func status(for phase: ChatMessageStreamPhase) -> MessageStatus {
        switch phase {
        case .pending, .streaming: return .streaming
        case .done: return .sent
        case .stopped: return .sent
        case .failed: return .failed
        }
    }

    // MARK: Recording

    /// Record one engine snapshot.
    ///
    /// - Streaming snapshot → debounce: held in `pending`, plan carries
    ///   `scheduleNextFlushAt = max(now, lastFlushAt + debounceInterval)`.
    /// - Terminal snapshot → flush-through: the final write plus any still
    ///   pending debounced writes go out immediately (never reorder a final
    ///   commit behind a stale streaming payload).
    @discardableResult
    public mutating func record(snapshot: StreamMessageSnapshot,
                                messageID: UUID,
                                conversationID: UUID,
                                now: Double) -> Plan {
        lastKnownNow = now
        let call = Call(
            message: StoredMessage(
                id: messageID, conversationID: conversationID,
                role: .assistant, content: snapshot.text,
                status: status(for: snapshot.state),
                createdAt: Date(timeIntervalSince1970: now)
            ),
            lastEventID: snapshot.lastEventID,
            at: now
        )

        if Self.isFinal(snapshot.state) {
            // Final commit: drop the stale streaming payload for this
            // message, write the terminal row now, and drain any other
            // pending debounced writes so ordering never inverts.
            pending.removeValue(forKey: snapshot.id)
            let others = pending.values.sorted { $0.at < $1.at }
            pending = [:]
            lastFlushAt = now
            return Plan(writes: others + [call])
        }

        // Streaming snapshot: emit the FULL-PREFIX upsert immediately
        // (idempotent replace — crash-safe, a cold launch loses at most one
        // 60ms commit) AND hold it in `pending` so the 500ms debounce timer
        // re-drains it as a retry heartbeat if a write ever failed.
        pending[snapshot.id] = call
        let next = max(now, lastFlushAt + Self.debounceInterval)
        return Plan(writes: [call], scheduleNextFlushAt: next)
    }

    /// Flush all debounced writes now (debounce timer fired / app
    /// backgrounding / engine stop). Returns what to persist.
    @discardableResult
    public mutating func flush(now: Double) -> Plan {
        let calls = pending.values.sorted { $0.at < $1.at }
        pending = [:]
        lastFlushAt = max(lastFlushAt, now)
        return Plan(writes: calls)
    }
}
