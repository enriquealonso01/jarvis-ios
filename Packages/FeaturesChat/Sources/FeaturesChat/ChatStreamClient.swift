import Foundation
import JarvisKit
import Persistence

/// Drives one conversation's live stream end-to-end (feature #1): the SSE
/// transport feeds this pipeline; UI reads `snapshots`; persistence happens
/// inside the pipeline. Owns cold-launch restore (task spec #3): read the
/// last snapshot from the store, then tail live from the resume point.
public actor ChatStreamClient {
    public enum Phase: Sendable, Equatable {
        case idle
        case restored(snapshotCount: Int)
        case streaming
        case stopped
    }

    private let config: ServerConfig
    private let conversationID: UUID
    private let store: PersistenceStore?
    private let session: URLSession
    private var client: SSEClient?
    private var consumeTask: Task<Void, Never>?
    private(set) var pipeline: ChatStreamPipeline?
    public private(set) var phase: Phase = .idle

    public init(config: ServerConfig, conversationID: UUID,
                store: PersistenceStore?, session: URLSession = .shared) {
        self.config = config
        self.conversationID = conversationID
        self.store = store
        self.session = session
    }

    /// Cold-launch restore (task spec #3): every message still in
    /// `streaming` status is seeded into the engine at its persisted text
    /// with its persisted resume pointer, so the transcript shows exactly
    /// what was committed before the app died and the live tail continues
    /// from the store's resume point. Returns how many messages were seeded.
    @discardableResult
    public func restoreFromStore() async -> Int {
        guard let store,
              let state = try? await store.streamRestoreState(conversationID: conversationID),
              let snapshot = state.snapshot else { return 0 }
        let pipe = pipelineOrNew()
        await pipe.restore(
            id: ChatStreamEngine.streamMessageID(forMessageUUID: snapshot.id),
            messageID: snapshot.id,
            text: snapshot.content,
            lastEventID: snapshot.lastEventID
        )
        phase = .restored(snapshotCount: 1)
        return 1
    }

    /// Resume pointer for the live tail: the max of what the store persisted
    /// and what the engine has applied (covers a mid-session restart).
    public var resumeEventID: Int64 {
        get async {
            var resume: Int64 = 0
            if let pipeline {
                resume = await pipeline.lastEventID
            }
            if let store,
               let state = try? await store.streamRestoreState(conversationID: conversationID) {
                resume = max(resume, state.resumeEventID)
            }
            return resume
        }
    }

    /// Open the live stream (after `restoreFromStore` when cold-launching).
    /// Pass `resumeAfter:` (or rely on `resumeEventID`) to seed the
    /// Last-Event-ID pointer; the server replays everything after it.
    public func start(resumeAfter: Int64? = nil) {
        consumeTask?.cancel()
        let sse = SSEClient(config: config, session: session)
        client = sse
        phase = .streaming
        consumeTask = Task { [weak self] in
            let resume = resumeAfter ?? (await self?.resumeEventID ?? 0)
            guard let self else { return }
            let stream = await sse.events(
                conversationID: self.conversationID,
                lastEventID: resume > 0 ? resume : nil
            )
            do {
                for try await event in stream {
                    await self.pipelineOrNew().ingest(event)
                }
                // Clean EOF with a message still open → treat as a
                // transport failure (retry affordance), never silent loss.
                await self.pipelineOrNew().failActiveIfStillStreaming()
            } catch {
                await self.pipelineOrNew().failActive()
            }
        }
    }

    /// User pressed stop: freeze partial content upstream (graceful SSE
    /// close, no error) + locally (UI Law §3).
    public func stop() async {
        await client?.close()
        consumeTask?.cancel()
        consumeTask = nil
        await pipelineOrNew().stop()
        phase = .stopped
    }

    /// Current UI snapshots (committed prefixes + pending buffers). Async
    /// getter: the pipeline is a separate actor.
    public var snapshots: [StreamMessageSnapshot] {
        get async { pipeline?.snapshots ?? [] }
    }

    // MARK: Internals

    private func pipelineOrNew() -> ChatStreamPipeline {
        if let pipeline { return pipeline }
        let fresh = ChatStreamPipeline(conversationID: conversationID, store: store)
        pipeline = fresh
        return fresh
    }
}

extension ChatStreamPipeline {
    /// failActive only when a message is still mid-stream (no-op otherwise;
    /// keeps the `for try await` error path and the clean-EOF path honest).
    func failActiveIfStillStreaming() async {
        let live = snapshots.contains {
            $0.state == .pending || $0.state == .streaming
        }
        if live { await failActive() }
    }
}
