import Foundation
import JarvisKit

// MARK: - StreamState (legacy surface, pinned by FeaturesChatTests)

/// Per-message stream text state. Kept as the plain-logic building block the
/// engine composes; its semantics are pinned by FeaturesChatTests.
public struct StreamState: Sendable, Equatable {
    public var isStreaming: Bool
    public var committedText: String
    public var pendingText: String

    public init(isStreaming: Bool = false, committedText: String = "", pendingText: String = "") {
        self.isStreaming = isStreaming
        self.committedText = committedText
        self.pendingText = pendingText
    }

    public var displayText: String { committedText + pendingText }

    public mutating func begin() {
        isStreaming = true
        pendingText = ""
    }

    public mutating func append(token: String) {
        guard isStreaming else { return }
        pendingText += token
    }

    /// Commit coalesced pending text (main-actor commits at ~50–100ms cadence).
    public mutating func commitPending() {
        committedText += pendingText
        pendingText = ""
    }

    /// Stop cancels upstream WITHOUT losing committed text (UI Law §3).
    public mutating func stop() {
        commitPending()
        isStreaming = false
    }
}

// MARK: - ChatStreamEngine (feature #1: streaming chat engine)

/// What happened when one AgentEvent frame was consumed.
public enum StreamConsumeEffect: Sendable, Equatable {
    /// A run/message appeared (or restarted) — create its pending state.
    case started
    /// A frame was folded into the buffer; nothing to render yet.
    case buffered
    /// Enough frames accumulated — flush the UI with current snapshots.
    case commitReady
    /// Terminal frame — flush once and move to a final state.
    case finished
}

/// Why a message left the `streaming` state (drives the UI affordance).
public enum StreamStopReason: Sendable, Equatable, Codable {
    /// Server acknowledged completion; full text committed as `sent`.
    case done
    /// User pressed stop: partial text is frozen, not discarded (UI Law §3).
    case stopped
    /// Transport/agent failure; partial text is kept and retry is offered.
    case failed
    /// Terminal failure — surfaced as a retry affordance (state only).
    case error
}

/// Immutable per-message snapshot the engine hands to the UI / persistence.
public struct StreamMessageSnapshot: Sendable, Equatable {
    public var id: Int64
    public var state: ChatMessageStreamPhase
    public var text: String
    public var lastEventID: Int64
    public var stopReason: StreamStopReason?
    /// UI affordance flag: offer "retry" after failure/error.
    public var retryAvailable: Bool

    public init(id: Int64, state: ChatMessageStreamPhase, text: String,
                lastEventID: Int64, stopReason: StreamStopReason? = nil,
                retryAvailable: Bool = false) {
        self.id = id
        self.state = state
        self.text = text
        self.lastEventID = lastEventID
        self.stopReason = stopReason
        self.retryAvailable = retryAvailable
    }
}

/// Lifecycle of one streamed assistant message (task-spec machine).
public enum ChatMessageStreamPhase: String, Sendable, Equatable, Codable {
    case pending, streaming, done, failed, stopped
}

/// A coalesced UI commit: full prefix snapshots of every message that
/// changed since the last commit (never per-token renders).
public struct StreamCommit: Sendable, Equatable {
    public var messages: [StreamMessageSnapshot]
    public init(messages: [StreamMessageSnapshot]) { self.messages = messages }
}

/// Consumes `AgentEvent` frames and produces coalesced UI commits.
///
/// - Per-message state machine: `pending → streaming → done|failed|stopped`
///   (task spec), driven by `token`/`message_start`/`done`/`stop`/`error`
///   frames (fixture contract, JarvisKit/Fixtures/contract.json).
/// - Coalesced commits: frames accumulate in a pending buffer; a commit is
///   due when ≥`minCommitInterval` (60ms) elapsed since the previous one or
///   on terminal frames (`done`/`stop`/`error`). Cadence is *controlled by
///   the caller's clock* — pass real time or a fake clock in tests. Never
///   call `commitIfDue` faster than the cadence; that's the throttle.
/// - Monotonic seq + dedupe: frames at or below the last applied seq per
///   message are dropped (resume replays are idempotent).
/// - `stop()` freezes partial content (state `stopped`); `error` frames mark
///   the message failed with a retry affordance flag (UI decides action).
///
/// Pure value logic — no I/O, no clocks of its own: unit-testable.
public struct ChatStreamEngine: Sendable, Equatable {
    /// Minimum interval between UI commits (plan feature #1: ~50–100ms).
    public static let minCommitInterval: Double = 0.060

    /// Frames the engine understands (fixture contract kinds).
    public enum Kind {
        public static let messageStart = "message_start"
        public static let token = "token"
        public static let done = "done"
        public static let stop = "stop"
        public static let error = "error"
    }

    // MARK: State (queryable; engine is a value type — snapshot/restore free)

    /// Monotonic dedupe watermark (highest applied event id).
    public private(set) var lastSeq: Int64 = 0
    /// Frames accepted since the last commit (deduped).
    public private(set) var bufferedCount = 0
    /// Messages with uncommitted buffered text.
    public private(set) var dirtyMessageIDs: Set<Int64> = []
    public private(set) var messages: [Int64: ChatStreamMessage] = [:]
    public private(set) var order: [Int64] = []
    /// The message id the next frame WITHOUT an explicit `message_id`
    /// targets: set by `message_start` (fixture contract — `token` frames
    /// carry raw text, so they attach to the currently open message). The
    /// pipeline reads `lastResolvedMessageID` so its UUID bookkeeping shares
    /// this exact mapping (one source of truth).
    private var currentMessageID: Int64?
    /// The message id the most recently consumed frame resolved to.
    public private(set) var lastResolvedMessageID: Int64?
    private var lastCommitAt: Double = -Double.infinity
    /// A terminal transition happened → next commit fires immediately
    /// (bypasses the cadence gate; `done`/`stop`/`error` must never be
    /// dropped for arriving within 60ms of the previous commit).
    private var terminalFlushPending = false

    public init() {}

    /// Deterministic stream-message-id for a persisted UUID (restore path).
    public static func streamMessageID(forMessageUUID uuid: UUID) -> Int64 {
        fnv1a(uuid.uuidString)
    }

    /// Shared frame → message-id mapping (engine + pipeline both call this;
    /// one source of truth). Per the fixture contract, only `message_start`,
    /// `done`/`stop`/`error` carry a `message_id` JSON payload — `token`
    /// frames carry raw text, so they resolve to the CURRENT message opened
    /// by `message_start` (or spawn a token-first message keyed by frame id).
    /// When the payload has a `message_id` it wins; otherwise the current
    /// message id is reused; the frame id is the last-resort fallback.
    public static func streamMessageID(for event: AgentEvent,
                                       current: Int64?) -> Int64 {
        if event.kind != Kind.token,
           let data = event.payload.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let raw = obj["message_id"] as? String {
            return fnv1a(raw)
        }
        // Token-first streams (no message_start seen): key by frame id so a
        // message still materializes; ids are monotonic so one token == one
        // key until a message_start arrives.
        return current ?? event.id
    }

    private static func fnv1a(_ raw: String) -> Int64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in raw.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int64(bitPattern: hash)
    }

    private mutating func messageID(for event: AgentEvent) -> Int64 {
        let resolved: Int64
        if event.kind == Kind.token, currentMessageID == nil,
           let last = lastResolvedMessageID,
           let m = messages[last],
           m.state == .pending || m.state == .streaming {
            resolved = last // token-first stream: extend the still-open message
        } else {
            resolved = Self.streamMessageID(for: event, current: currentMessageID)
        }
        lastResolvedMessageID = resolved
        return resolved
    }

    /// Cold-launch restore: seed a live message from its persisted snapshot
    /// WITHOUT consuming frames — the content is already committed store
    /// state, and `lastEventID` lifts the dedupe watermark so a server
    /// replay of already-seen events is dropped client-side (idempotent
    /// resume even if the Last-Event-ID header path is unavailable).
    public mutating func seed(id: Int64, text: String, lastEventID: Int64) {
        start(id: id)
        guard var m = messages[id] else { return }
        m.state = text.isEmpty ? .pending : .streaming
        m.text = text
        m.lastEventID = lastEventID
        messages[id] = m
        lastSeq = max(lastSeq, lastEventID)
        // The live tail continues INTO the restored message: raw `token`
        // frames (no message_id) must append to it, not spawn a new one.
        currentMessageID = id
    }

    // MARK: Per-message state

    public struct ChatStreamMessage: Sendable, Equatable {
        public var id: Int64
        public var state: ChatMessageStreamPhase
        public var text: String
        public var lastEventID: Int64
        public var stopReason: StreamStopReason?
        /// UI affordance flag: offer "retry" after failure/error.
        public var retryAvailable: Bool

        public init(id: Int64) {
            self.id = id
            self.state = .pending
            self.text = ""
            self.lastEventID = 0
            self.stopReason = nil
            self.retryAvailable = false
        }

        public var snapshot: StreamMessageSnapshot {
            StreamMessageSnapshot(id: id, state: state, text: text,
                                  lastEventID: lastEventID, stopReason: stopReason,
                                  retryAvailable: retryAvailable)
        }
    }

    // MARK: Event consumption

    /// Consume one frame. Returns what happened; call `commitIfDue(now:)`
    /// after any non-`.buffered` result.
    @discardableResult
    public mutating func consume(_ event: AgentEvent) -> StreamConsumeEffect {
        guard event.id > lastSeq else { return .buffered } // dedupe replay
        lastSeq = event.id

        switch event.kind {
        case Kind.messageStart:
            let id = messageID(for: event)
            if messages[id] == nil { start(id: id) }
            // A `message_start` re-opens its message; raw `token` frames that
            // follow (no message_id per the fixture contract) attach here.
            // Re-starting a KNOWN message is a no-op — a resume replay must
            // never wipe already-accumulated/restored text.
            currentMessageID = id
            return .started
        case Kind.token:
            let id = messageID(for: event)
            if messages[id] == nil { start(id: id) } // token-first streams
            guard var m = messages[id] else { return .buffered }
            guard m.state == .pending || m.state == .streaming else {
                return .buffered // late tokens after a terminal frame: ignored
            }
            m.state = .streaming
            m.text += event.payload
            m.lastEventID = event.id
            messages[id] = m
            dirtyMessageIDs.insert(id)
            bufferedCount += 1
            return .buffered
        case Kind.done:
            return finish(kind: Kind.done, event: event, phase: .done, retry: false)
        case Kind.stop:
            return finish(kind: Kind.stop, event: event, phase: .stopped, retry: false)
        case Kind.error:
            return finish(kind: Kind.error, event: event, phase: .failed, retry: true)
        default:
            return .buffered // unknown kinds are buffered, never crash
        }
    }

    // MARK: Coalesced commits

    /// True when a UI commit should fire now (cadence elapsed, or a terminal
    /// transition is pending — those flush immediately).
    public mutating func shouldCommit(now: Double) -> Bool {
        guard !dirtyMessageIDs.isEmpty else { return false }
        if terminalFlushPending { return true }
        return now - lastCommitAt >= Self.minCommitInterval
    }

    /// Flush pending text into committed snapshots for all dirty messages and
    /// return the commit (prefix snapshots — safe to render as-is).
    @discardableResult
    public mutating func commitIfDue(now: Double) -> StreamCommit? {
        guard shouldCommit(now: now) else { return nil }
        let ids = dirtyMessageIDs
        dirtyMessageIDs = []
        bufferedCount = 0
        lastCommitAt = now
        terminalFlushPending = false
        let snaps = ids.compactMap { id -> StreamMessageSnapshot? in
            guard let m = messages[id] else { return nil }
            return m.snapshot
        }
        return StreamCommit(messages: snaps)
    }

    // MARK: Control surface

    /// User pressed stop: freeze partial content, mark stopped (UI Law §3).
    /// The stop target is the active message, or a specific one. The commit
    /// fires immediately (terminal transitions bypass the 60ms cadence).
    @discardableResult
    public mutating func stop(id: Int64? = nil, now: Double) -> StreamCommit? {
        let target = id ?? activeMessageID
        guard let target else { return nil }
        guard var m = messages[target] else { return nil }
        guard m.state == .pending || m.state == .streaming else {
            // Nothing active: still honor an explicit stop as a no-op commit.
            return nil
        }
        m.state = .stopped
        m.stopReason = .stopped
        m.retryAvailable = false
        messages[target] = m
        dirtyMessageIDs.insert(target)
        terminalFlushPending = true
        return commitIfDue(now: now)
    }

    /// Transport died mid-stream: keep partial text, offer retry. The commit
    /// fires immediately (terminal transitions bypass the 60ms cadence).
    @discardableResult
    public mutating func failActive(now: Double) -> StreamCommit? {
        guard let id = activeMessageID, var m = messages[id] else { return nil }
        m.state = .failed
        m.stopReason = .failed
        m.retryAvailable = true
        messages[id] = m
        dirtyMessageIDs.insert(id)
        terminalFlushPending = true
        return commitIfDue(now: now)
    }

    /// Mark a failed message's retry as started (back to pending).
    public mutating func beginRetry(id: Int64) {
        guard var m = messages[id] else { return }
        m.state = .pending
        m.stopReason = .failed
        m.retryAvailable = false
        messages[id] = m
    }

    /// Snapshot one message (UI render / persistence writer).
    public func snapshot(id: Int64) -> StreamMessageSnapshot? {
        messages[id]?.snapshot
    }

    /// All messages in arrival order.
    public var snapshots: [StreamMessageSnapshot] {
        order.compactMap { messages[$0]?.snapshot }
    }

    /// Highest seq among non-terminal messages, if any (resume pointer seed).
    public var resumeID: Int64? {
        let live = order.compactMap { messages[$0] }
            .filter { $0.state == .pending || $0.state == .streaming }
        guard let maxLive = live.map(\.lastEventID).max() else { return nil }
        return maxLive
    }

    // MARK: Internals

    private var activeMessageID: Int64? {
        order.reversed().lazy
            .first { messages[$0]?.state == .pending || messages[$0]?.state == .streaming } ?? nil
    }

    private mutating func start(id: Int64) {
        if messages[id] == nil { order.append(id) }
        messages[id] = ChatStreamMessage(id: id)
        dirtyMessageIDs.insert(id)
    }

    private mutating func finish(kind: String, event: AgentEvent,
                                 phase: ChatMessageStreamPhase, retry: Bool) -> StreamConsumeEffect {
        let id = messageID(for: event)
        currentMessageID = nil // terminal frame closes the current message
        guard var m = messages[id] else {
            // Terminal frame for an unknown/empty message: record it so the
            // transcript never shows a phantom entry, and move on.
            start(id: id)
            guard var m2 = messages[id] else { return .buffered }
            m2.state = phase
            m2.stopReason = stopReason(for: kind)
            m2.retryAvailable = retry
            m2.lastEventID = event.id
            messages[id] = m2
            dirtyMessageIDs.insert(id)
            terminalFlushPending = true
            return .finished
        }
        guard m.state == .pending || m.state == .streaming else { return .buffered }
        m.state = phase
        m.stopReason = stopReason(for: kind)
        m.retryAvailable = retry
        m.lastEventID = event.id
        messages[id] = m
        dirtyMessageIDs.insert(id)
        terminalFlushPending = true
        return .finished
    }

    private func stopReason(for kind: String) -> StreamStopReason {
        switch kind {
        case Kind.done: return .done
        case Kind.stop: return .stopped
        case Kind.error: return .error
        default: return .done
        }
    }
}
