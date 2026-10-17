import Foundation
import JarvisKit
import Persistence

/// Wires the three Item 2 pieces into one ingest pipeline (plan feature #1 +
/// §5.3): SSE frames → `ChatStreamEngine` state machine → coalesced UI
/// commits → debounced persistence writes. The engine (pure value) lives
/// inside the actor; its state mutates only here, so resume bookkeeping is
/// race-free.
///
/// The UI consumes `ChatStreamClient` (which drives this pipeline); tests can
/// drive the pipeline directly frame-by-frame.
public actor ChatStreamPipeline {
    private let conversationID: UUID
    private let store: PersistenceStore?
    private var writer: StreamPersistenceWriter
    private var engine = ChatStreamEngine()
    private var pendingFlushTask: Task<Void, Never>?
    /// Stream-message-id → local UUID (stable across frames of one run).
    private var messageIDs: [Int64: UUID] = [:]
    private var clock: @Sendable () -> Double

    public init(conversationID: UUID,
                store: PersistenceStore?,
                writer: StreamPersistenceWriter = StreamPersistenceWriter(),
                clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.conversationID = conversationID
        self.store = store
        self.writer = writer
        self.clock = clock
    }

    /// Current engine snapshots (UI renders from this, not from events).
    public var snapshots: [StreamMessageSnapshot] { engine.snapshots }

    /// Highest applied event id (persist as the resume pointer).
    public var lastEventID: Int64 { engine.lastSeq }

    /// Frame-id of the most recent message the engine resolved — lets
    /// `ensureLocalUUID` carry a minted UUID when `message_start` re-keys a
    /// token-first message onto a payload-id key.
    private var lastFrameStreamID: Int64?

    // MARK: Restore (cold launch)

    /// Seed a persisted partial message into the engine so the live tail
    /// continues from the store's resume point (task spec #3). `streamID`
    /// must come from `ChatStreamEngine.streamMessageID(forMessageUUID:)` so
    /// the engine's targets and the persistence UUIDs stay in agreement.
    public func restore(id streamID: Int64, messageID: UUID,
                        text: String, lastEventID: Int64) {
        messageIDs[streamID] = messageID
        engine.seed(id: streamID, text: text, lastEventID: lastEventID)
    }

    // MARK: Event ingestion

    /// Consume one agent frame and run the commit/persistence steps its
    /// effect requires. Cheap enough to call per frame.
    public func ingest(_ event: AgentEvent) async {
        switch engine.consume(event) {
        case .started, .commitReady, .finished:
            ensureLocalUUID(forFrameOf: event)
            await commitEngine(now: clock())
        case .buffered:
            break
        }
        if engine.shouldCommit(now: clock()) {
            await commitEngine(now: clock())
        }
    }

    /// Timer-driven flush (the writer's debounce plan).
    public func flushDueWrites() async {
        await flushWriter(now: clock())
    }

    // MARK: Control

    /// User stop: freeze partial content upstream + locally (UI Law §3).
    /// The stopped snapshot is terminal → the writer flushes it through the
    /// debounce immediately, so the store freezes the same text the UI froze.
    public func stop() async {
        if let commit = engine.stop(now: clock()) {
            await persist(commit: commit)
        }
        await flushWriter(now: clock())
    }

    /// Transport died mid-stream: partial text survives, retry offered.
    public func failActive() async {
        if let commit = engine.failActive(now: clock()) {
            await persist(commit: commit)
        }
        await flushWriter(now: clock())
    }

    // MARK: Internals

    private func commitEngine(now: Double) async {
        if let commit = engine.commitIfDue(now: now) {
            await persist(commit: commit)
        }
    }

    private func persist(commit: StreamCommit) async {
        for snapshot in commit.messages {
            let plan = writer.record(snapshot: snapshot,
                                     messageID: localUUID(forMessage: snapshot.id),
                                     conversationID: conversationID,
                                     now: clock())
            if let at = plan.scheduleNextFlushAt {
                scheduleFlush(at: at)
            }
            await executeWrites(plan)
        }
    }

    private func executeWrites(_ plan: StreamPersistenceWriter.Plan) async {
        guard let store else { return }
        for call in plan.writes {
            if StreamPersistenceWriter.isFinal(messageStatus(for: call.message.status)) {
                // Terminal: status sent/failed + conversation preview/timestamp.
                try? await store.finalizeStreamedMessage(
                    id: call.message.id,
                    conversationID: call.message.conversationID,
                    text: call.message.content,
                    failed: call.message.status == .failed,
                    lastEventID: call.lastEventID
                )
            } else {
                // Debounced delta: full-prefix snapshot replace (idempotent,
                // cold-launch-safe) + resume pointer.
                try? await store.applyStreamDelta(
                    messageID: call.message.id,
                    conversationID: call.message.conversationID,
                    role: call.message.role,
                    delta: call.message.content,
                    replaceBody: true,
                    lastEventID: call.lastEventID
                )
            }
        }
    }

    /// The writer stores terminal rows as `MessageStatus`; the final/delta
    /// decision in the store layer keys off the SAME phase the writer used.
    private func messageStatus(for status: MessageStatus) -> ChatMessageStreamPhase {
        switch status {
        case .streaming: return .streaming
        case .sent: return .done
        case .failed: return .failed
        case .sending: return .pending
        }
    }

    private func flushWriter(now: Double) async {
        let plan = writer.flush(now: now)
        await executeWrites(plan)
    }

    /// Debounce timer as a detached task (the delay must not block event
    /// ingestion; the flush itself serializes on the actor).
    private func scheduleFlush(at date: Double) {
        let delay = max(0, date - clock())
        pendingFlushTask?.cancel()
        pendingFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.flushDueWrites()
        }
    }

    /// One UUID per stream message. The server-sent `message_id` (fixture
    /// contract) wins — stable across reconnects, so a resume replay of the
    /// same run lands on the SAME row (idempotent). Token-first messages
    /// without a payload id mint a fresh UUID once.
    private func ensureLocalUUID(forFrameOf event: AgentEvent) {
        guard let streamID = engine.lastResolvedMessageID else { return }
        guard messageIDs[streamID] == nil else { return }
        if let data = event.payload.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let raw = obj["message_id"] as? String,
           let uuid = UUID(uuidString: raw) {
            messageIDs[streamID] = uuid
        } else if let previous = lastFrameStreamID,
                  let carried = messageIDs[previous],
                  previous != streamID {
            // message_start re-keyed a token-first message: keep its row.
            messageIDs[streamID] = carried
        } else {
            messageIDs[streamID] = UUID()
        }
        lastFrameStreamID = streamID
    }

    private func localUUID(forMessage streamID: Int64) -> UUID {
        if let existing = messageIDs[streamID] { return existing }
        let fresh = UUID()
        messageIDs[streamID] = fresh
        return fresh
    }
}
