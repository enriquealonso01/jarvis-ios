import Foundation
import SwiftUI
import JarvisKit
import Persistence
import DesignSystem

// MARK: - Item 8: Transcript / thread view (features #1 + #2 completion)
//
// UI Law, verbatim:
//   §2 Bubbles — user messages: right-aligned tinted rounded rectangles,
//      max ~85% width. Assistant messages: FULL-WIDTH, NO BUBBLE; the
//      avatar/label sits at the conversation head. Never bubble the assistant.
//   §3 Streaming — tokens stream into the assistant block (rendered from the
//      Item-2 engine's coalesced snapshots + the PersistenceStore rows); the
//      send button becomes a stop (square) button mid-stream; stop cancels
//      upstream WITHOUT losing committed text.
//   §5 Scroll anchoring — auto-scroll ONLY when already at bottom; never
//      fight the user mid-stream; monotonic bottom buffer (~50pt, added
//      once, never removed).
//
// Pure decision logic (windowing, merge, anchoring) lives in
// `TranscriptLayoutEngine` so the M1 exit gates exercise it headlessly.

/// Render-model row: one transcript entry (stored or live overlay).
public struct TranscriptRow: Identifiable, Equatable, Sendable {
    public enum Origin: Equatable, Sendable {
        case stored   // GRDB row
        case live     // streaming snapshot (assistant tail)
    }

    /// Stable identity: "m:<uuid>" for stored rows, "s:<int64>" for live.
    public let id: String
    public let isUser: Bool
    public let text: String
    public let status: MessageStatus
    /// UI affordance after a failure (UI Law §3: interruptible without loss).
    public let retryAvailable: Bool
    public let origin: Origin

    public init(id: String, isUser: Bool, text: String, status: MessageStatus,
                retryAvailable: Bool = false, origin: Origin) {
        self.id = id
        self.isUser = isUser
        self.text = text
        self.status = status
        self.retryAvailable = retryAvailable
        self.origin = origin
    }
}

/// Pure layout/merge decisions for the transcript (headless-testable; no
/// SwiftUI, no actors — the M1 exit-gate smokes drive these directly).
public enum TranscriptLayoutEngine: Sendable {

    /// Windowed-rendering cap: at most this many rows materialize into the
    /// list no matter how large the conversation (M1 1k-message gate — the
    /// render surface is bounded, memory stays O(window)).
    public static let maxVisibleMessages = 200

    /// §5 monotonic bottom buffer base (DesignSystem is the only source of
    /// layout constants — same 50pt the sidebar uses).
    public static var defaultBottomBuffer: CGFloat { Tokens.Sidebar.scrollBottomBuffer }

    // MARK: §5 scroll anchoring

    /// Auto-scroll ONLY when the view is already at the bottom — never fight
    /// the user mid-stream.
    public static func shouldAutoScroll(isAtBottom: Bool) -> Bool { isAtBottom }

    /// Monotonic bottom buffer: added once (to base), never removed, never
    /// shrunk (monotonic max) — no layout shift when content grows.
    public static func grownBottomBuffer(current: CGFloat,
                                         base: CGFloat = TranscriptLayoutEngine.defaultBottomBuffer) -> CGFloat {
        max(current, base)
    }

    // MARK: Windowing (M1 1k-message gate)

    /// Which slice of a merged row array renders: always the newest tail,
    /// at most `maxVisibleMessages` entries.
    public static func windowRange(totalCount: Int) -> Range<Int> {
        let start = max(0, totalCount - maxVisibleMessages)
        return start..<max(start, totalCount)
    }

    // MARK: Merge (stored page + live overlay)

    /// Map a streaming phase to the row status the transcript renders.
    static func rowStatus(for phase: ChatMessageStreamPhase) -> MessageStatus {
        switch phase {
        case .pending: return .sending
        case .streaming: return .streaming
        case .done: return .sent
        // Stop freezes partial content (§3) — the store writes it as `sent`
        // too; the transcript shows the same "kept" semantics.
        case .stopped: return .sent
        case .failed: return .failed
        }
    }

    /// Merge the stored page and the live streaming snapshots into render
    /// rows, then window to the newest `maxVisibleMessages`.
    ///
    /// Overlay routing (no dup, no gap):
    ///   • A stored assistant row claimed by a live snapshot (via the
    ///     stream-id → UUID map) is HIDDEN — the overlay is fresher.
    ///   • Once the store's row for a mapped UUID is terminal (.sent/.failed)
    ///     the overlay is DROPPED — the store is authoritative again. Timing-
    ///     safe: until finalize lands, the overlay stays and nothing is lost.
    public static func renderRows(stored: [StoredMessage],
                                  live: [StreamMessageSnapshot],
                                  liveMessageIDs: [Int64: UUID] = [:]) -> [TranscriptRow] {
        var rows: [TranscriptRow] = stored.map { message in
            TranscriptRow(
                id: "m:\(message.id.uuidString)",
                isUser: message.role == .user,
                text: message.content,
                status: message.status,
                retryAvailable: false,
                origin: .stored)
        }

        let anyOverlay = !live.isEmpty
        let claimedUUIDs = Set(liveMessageIDs.values.map(\.uuidString))
        if anyOverlay {
            // Live stream owns these rows: hide the stored copies (a claimed
            // row, or any still-.streaming row — the cold-launch restore
            // seeds exactly those into the overlay).
            rows.removeAll { row in
                guard !row.isUser else { return false }
                let storedID = row.id.dropFirst("m:".count)
                return row.status == .streaming || claimedUUIDs.contains(storedID)
            }
        }

        // Store-authoritative terminal rows retire their overlay twin.
        let terminalStored = Set(
            stored.filter { $0.status == .sent || $0.status == .failed }
                .map(\.id.uuidString))

        for snapshot in live {
            if let uuid = liveMessageIDs[snapshot.id],
               terminalStored.contains(uuid.uuidString) {
                continue
            }
            rows.append(TranscriptRow(
                id: "s:\(snapshot.id)",
                isUser: false,
                text: snapshot.text,
                status: rowStatus(for: snapshot.state),
                retryAvailable: snapshot.retryAvailable,
                origin: .live))
        }

        let range = windowRange(totalCount: rows.count)
        return Array(rows[range])
    }
}

// MARK: - View model

/// Store-backed transcript view model (UI Law §2/§3/§5). Loads the newest
/// page from the PersistenceStore, live-tails the streaming snapshots for
/// the active conversation, merges both through `TranscriptLayoutEngine`.
/// With `streamClient: nil` (tests / degraded store) it is fully headless —
/// no network is ever touched.
@MainActor
public final class TranscriptViewModel: ObservableObject {

    /// Scroll anchor id for the §5 bottom pin.
    public static let bottomAnchorID = "transcript.bottomAnchor"

    // MARK: Published state

    @Published public private(set) var displayRows: [TranscriptRow] = []
    /// True while any live snapshot is pending/streaming (§3 stop affordance).
    @Published public private(set) var isStreaming = false
    /// §5 monotonic bottom buffer (added once, never removed).
    @Published public private(set) var bottomBuffer: CGFloat = 0
    /// Whether the user is currently scrolled to the bottom (auto-scroll gate).
    @Published public var isAtBottom = true

    // MARK: Dependencies

    public let conversationID: UUID
    private let store: PersistenceStore?
    private let client: ChatStreamClient?
    private var tailTask: Task<Void, Never>?
    private var storedPage: [StoredMessage] = []
    private var liveSnapshots: [StreamMessageSnapshot] = []
    private var liveMessageIDs: [Int64: UUID] = [:]

    public init(conversationID: UUID,
                store: PersistenceStore?,
                streamClient: ChatStreamClient? = nil) {
        self.conversationID = conversationID
        self.store = store
        self.client = streamClient
    }

    deinit { tailTask?.cancel() }

    // MARK: Loading (cold-launch restore shows the full transcript)

    /// Newest page from the store + live-tail resume when a stream was
    /// mid-flight (cold launch mid-stream restores the transcript; plan §6).
    public func loadInitial() async {
        await reloadStored()
        if let client {
            let restored = await client.restoreFromStore()
            if restored > 0 {
                let state = await client.transcriptState
                updateLiveState(snapshots: state.snapshots, messageIDs: state.messageIDs)
                await client.start(resumeAfter: nil)
                beginTailLoop()
            }
        }
        refreshDisplay()
    }

    /// The composer sent a user row: refresh the page and make sure the live
    /// tail is running so the assistant reply streams into the block (§3).
    public func userDidSend() async {
        await reloadStored()
        if let client {
            let phase = await client.phase
            if phase != .streaming {
                await client.restoreFromStore() // no-op when nothing mid-stream
                await client.start(resumeAfter: nil)
            }
            beginTailLoop()
        }
        refreshDisplay()
    }

    /// §3 stop: cancel upstream WITHOUT losing committed text (the engine
    /// freezes + persists the partial; the composer's square button lands here).
    public func stopTapped() async {
        tailTask?.cancel()
        tailTask = nil
        await client?.stop()
        await reloadStored()
        if let client {
            let state = await client.transcriptState
            updateLiveState(snapshots: state.snapshots, messageIDs: state.messageIDs)
        }
        refreshDisplay()
    }

    /// Retry affordance on a failed tail (UI Law §3: retry offered, lossless).
    public func retryTapped() async {
        await userDidSend()
    }

    // MARK: Live-state injection (tail loop + headless tests)

    /// Replace the live overlay snapshots + their stream-id → UUID routing.
    public func updateLiveState(snapshots: [StreamMessageSnapshot],
                                messageIDs: [Int64: UUID]) {
        liveSnapshots = snapshots
        liveMessageIDs = messageIDs
        refreshDisplay()
    }

    // MARK: §5 helpers the view drives

    /// Monotonic: grows to the base buffer on first appearance, never shrinks.
    public func markBottomBufferNeeded() {
        bottomBuffer = TranscriptLayoutEngine.grownBottomBuffer(current: bottomBuffer)
    }

    /// Auto-scroll decision (only when already at bottom, §5).
    public var shouldAutoScroll: Bool {
        TranscriptLayoutEngine.shouldAutoScroll(isAtBottom: isAtBottom)
    }

    // MARK: Internals

    private func reloadStored() async {
        guard let store else {
            storedPage = []
            return
        }
        storedPage = (try? await store.recentMessages(conversationID: conversationID, page: 0)) ?? []
    }

    /// Coalesced-refresh the render output (engine merge + window).
    public func refreshDisplay() {
        displayRows = TranscriptLayoutEngine.renderRows(
            stored: storedPage,
            live: liveSnapshots,
            liveMessageIDs: liveMessageIDs)
        isStreaming = liveSnapshots.contains {
            $0.state == .pending || $0.state == .streaming
        }
    }

    /// Poll the stream client's coalesced snapshots (the engine's commit
    /// cadence already throttles renders — this only mirrors them into
    /// published state). Exits once the stream is terminal AND the store has
    /// absorbed the finalized rows (overlay retired, no dup, no gap).
    private func tailLoop() async {
        defer { tailTask = nil }
        while !Task.isCancelled {
            guard let client else { return }
            let state = await client.transcriptState
            let phase = await client.phase
            updateLiveState(snapshots: state.snapshots, messageIDs: state.messageIDs)

            if phase == .stopped {
                await reloadStored()
                return
            }
            let live = state.snapshots.contains {
                $0.state == .pending || $0.state == .streaming
            }
            if !live, !state.snapshots.isEmpty {
                // Terminal transition: the pipeline persists the finalized row
                // before the snapshot turns terminal, but re-read once to be
                // certain the store row retires the overlay (no dup on lag).
                await reloadStored()
                return
            }
            if state.snapshots.isEmpty && phase == .idle {
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func beginTailLoop() {
        if let tailTask, !tailTask.isCancelled { return }
        tailTask = Task { [weak self] in
            await self?.tailLoop()
        }
    }

    /// Stop mirroring the stream (conversation switched / view gone).
    public func cancelTail() {
        tailTask?.cancel()
        tailTask = nil
    }
}

// MARK: - The transcript view (UI Law §2/§3/§5)

public struct V2TranscriptView: View {
    @ObservedObject public var vm: TranscriptViewModel

    public init(vm: TranscriptViewModel) {
        self.vm = vm
    }

    public var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                        conversationHead
                        ForEach(vm.displayRows) { row in
                            TranscriptRowView(
                                row: row,
                                availableWidth: geo.size.width,
                                onRetry: (row.origin == .live && row.retryAvailable)
                                    ? { Task { await vm.retryTapped() } }
                                    : nil)
                        }
                        workingIndicator
                        Color.clear
                            .frame(height: vm.bottomBuffer)
                            .id(TranscriptViewModel.bottomAnchorID)
                            .onAppear { vm.isAtBottom = true }
                            .onDisappear { vm.isAtBottom = false }
                    }
                    .padding(.horizontal, Tokens.Spacing.l)
                    .padding(.top, Tokens.Spacing.s)
                }
                .onChange(of: vm.displayRows) { _, _ in
                    // §5: auto-scroll ONLY when already at bottom — never
                    // fight the user mid-stream.
                    if vm.shouldAutoScroll {
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(TranscriptViewModel.bottomAnchorID, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("transcript.scrollView")
        .onAppear { vm.markBottomBufferNeeded() }
    }

    /// §2: avatar/label at the conversation head (assistant never bubbles).
    private var conversationHead: some View {
        HStack(spacing: Tokens.Spacing.s) {
            Image(systemName: "sparkles")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor))
            Text("JARVIS")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .accessibilityIdentifier("transcript.conversationHead")
    }

    /// §3 working indicator while the tail is open but has no text yet.
    @ViewBuilder
    private var workingIndicator: some View {
        if vm.isStreaming,
           vm.displayRows.last?.text.isEmpty ?? false {
            HStack(spacing: Tokens.Spacing.s) {
                ProgressView()
                Text("JARVIS is working…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("transcript.workingIndicator")
        }
    }
}

/// One row: user = right-aligned tinted bubble ≤85% width; assistant =
/// full-width, no bubble (UI Law §2 — never bubble the assistant).
struct TranscriptRowView: View {
    let row: TranscriptRow
    let availableWidth: CGFloat
    var onRetry: (() -> Void)? = nil

    init(row: TranscriptRow, availableWidth: CGFloat, onRetry: (() -> Void)? = nil) {
        self.row = row
        self.availableWidth = availableWidth
        self.onRetry = onRetry
    }

    var body: some View {
        if row.isUser {
            userBubble
        } else {
            assistantBlock
        }
    }

    private var userBubble: some View {
        HStack(alignment: .bottom) {
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.text)
                    .textSelection(.enabled)
                if row.status == .sending {
                    Text("Sending…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if row.status == .failed {
                    Text("Not delivered")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, Tokens.Spacing.m)
            .padding(.vertical, Tokens.Spacing.s)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.accentColor.opacity(0.18))
            )
            .frame(maxWidth: availableWidth * Tokens.Bubble.maxWidthFraction,
                   alignment: .trailing)
        }
        .accessibilityIdentifier("transcript.message.\(row.id)")
    }

    private var assistantBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Full-width, no bubble (§2). Fixed vertical growth so streaming
            // text reflows without horizontal truncation.
            Text(row.text.isEmpty ? " " : row.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if row.status == .failed {
                HStack(spacing: Tokens.Spacing.s) {
                    Text("Failed")
                        .font(.caption)
                        .foregroundStyle(.red)
                    if row.retryAvailable {
                        Button("Retry") {
                            Task { await retry() }
                        }
                        .font(.caption.weight(.semibold))
                        .accessibilityIdentifier("transcript.retry")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("transcript.message.\(row.id)")
    }

    private func retry() {
        onRetry?()
    }
}
