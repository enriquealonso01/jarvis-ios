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
            // Live stream owns these rows: hide the stored copies while the
            // store's copy is NOT yet terminal (a claimed row still pending,
            // or any still-.streaming row — the cold-launch restore seeds
            // exactly those into the overlay). Terminal (.sent/.failed)
            // stored copies stay visible: the store has absorbed the final
            // text, so hiding them would open a gap when the overlay drops.
            rows.removeAll { row in
                guard !row.isUser else { return false }
                if row.status == .streaming { return true }
                if row.status == .sent || row.status == .failed { return false }
                let storedID = String(row.id.dropFirst("m:".count))
                return claimedUUIDs.contains(storedID)
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
    /// NOT @Published: it is written from the bottom anchor's
    /// onAppear/onDisappear (i.e. during layout) and only READ by the
    /// auto-scroll decision. Publishing it re-rendered the whole transcript
    /// from inside layout; with tall rich cards the lazy stack's estimates
    /// made the anchor flip appear/disappear every frame — a 100% CPU
    /// render loop (sampled in the QA lane: LazySubviewPlacements forever).
    public var isAtBottom = true

    // MARK: Item 11 — rich blocks (additive)

    /// Block-interaction state for this transcript. Per-message isolated
    /// (keys are `"<rowID>|<blockID>"`); a regenerate produces a NEW message
    /// id, so interactive state never leaks across turns by construction.
    @Published public private(set) var richInteractions = RichInteractionStore()

    /// The rich blocks a row renders (nil = plain text). Extracted once per
    /// refresh into `rowRichBlocks` so parsing is NOT re-run from the view
    /// body on every layout pass.
    @Published public private(set) var rowRichBlocks: [String: [RichBlock]] = [:]

    /// Lookup seam the row view consumes (nil = ordinary text row).
    public func richBlocks(for row: TranscriptRow) -> [RichBlock]? {
        rowRichBlocks[row.id]
    }

    private static func extractRichBlocks(_ rows: [TranscriptRow]) -> [String: [RichBlock]] {
        var map: [String: [RichBlock]] = [:]
        for row in rows where !row.isUser {
            if let blocks = RichContentPayload.parse(row.text) {
                map[row.id] = blocks
            }
        }
        return map
    }

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
        let rows = TranscriptLayoutEngine.renderRows(
            stored: storedPage,
            live: liveSnapshots,
            liveMessageIDs: liveMessageIDs)
        // Publish only real changes: the live tail polls every 100 ms, and
        // re-assigning identical rows re-rendered the whole transcript (rich
        // cards, markdown) ten times a second — enough to keep the main
        // thread from ever going idle (XCTest "main thread busy" in the QA
        // lane while a stalled stream sat in the Krendora chat).
        if rows != displayRows {
            displayRows = rows
            // Item 11: re-extract rich payloads alongside the rows (once per
            // change, not per layout pass).
            rowRichBlocks = TranscriptViewModel.extractRichBlocks(rows)
        }
        let streaming = liveSnapshots.contains {
            $0.state == .pending || $0.state == .streaming
        }
        if streaming != isStreaming {
            isStreaming = streaming
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
        // Item 11: regenerate/teardown resets per-message interaction state
        // (PLAN_DELTA §D: "reset on regenerate").
        richInteractions.resetAll()
    }
}

// MARK: - The transcript view (UI Law §2/§3/§5)
//
// Look: UI-expansion 03_SCREEN_SPECS + prototype. Obsidian canvas, assistant
// answers float full-width directly on the canvas (never bubbled), user turns
// are deep-surface bubbles with a tail corner, 16pt gutters, readable column
// capped on wide layouts.

public struct V2TranscriptView: View {
    @ObservedObject public var vm: TranscriptViewModel
    /// Item 9: the completed-message action row. `nil` (the default) keeps
    /// Item-8 call sites and headless tests unchanged — no action row.
    public var actionViewModel: MessageActionViewModel? = nil
    /// Real regenerate send path (app wires the coordinator); `nil` omits
    /// the regenerate control entirely (no fake buttons).
    public var regenerateSend: MessageActionViewModel.PerformSend? = nil
    /// The chat's send path for rich-block interactions (button labels, poll
    /// votes, form submissions). `nil` = those controls stay local / hidden.
    public var onSendText: ((String) -> Void)? = nil

    public init(vm: TranscriptViewModel,
                actionViewModel: MessageActionViewModel? = nil,
                regenerateSend: MessageActionViewModel.PerformSend? = nil,
                onSendText: ((String) -> Void)? = nil) {
        self.vm = vm
        self.actionViewModel = actionViewModel
        self.regenerateSend = regenerateSend
        self.onSendText = onSendText
    }

    public var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    // Eager VStack, not LazyVStack: the transcript is already
                    // windowed (≤ maxVisibleMessages rows), and the lazy stack's
                    // off-screen height estimates for tall rich cards never
                    // settled (QA-lane samples: LazySubviewPlacements at 100%
                    // CPU after a card above the viewport changed height).
                    VStack(alignment: .leading, spacing: Tokens.Layout.messageSpacing) {
                        if vm.displayRows.isEmpty {
                            welcome(minHeight: geo.size.height * 0.72)
                        } else {
                            conversationHead
                        }
                        ForEach(vm.displayRows) { row in
                            let rowIndex = vm.displayRows.firstIndex(where: { $0.id == row.id })
                            let isLast = rowIndex == vm.displayRows.count - 1
                            let rowRegenPrompt: String? = (rowIndex != nil && isLast && !row.isUser)
                                ? lastUserPrompt(rows: vm.displayRows, upTo: rowIndex!)
                                : nil
                            VStack(alignment: row.isUser ? .trailing : .leading, spacing: 4) {
                                TranscriptRowView(
                                    row: row,
                                    availableWidth: geo.size.width,
                                    onRetry: (row.origin == .live && row.retryAvailable)
                                        ? { Task { await vm.retryTapped() } }
                                        : nil,
                                    richBlocks: vm.richBlocks(for: row),
                                    richInteractions: vm.richInteractions,
                                    onSendText: onSendText)
                                if let actionVM = actionViewModel {
                                    MessageActionRowView(
                                        row: row,
                                        isLastRow: isLast,
                                        canRegenerate: regenerateSend != nil,
                                        vm: actionVM,
                                        onRegenerate: (rowRegenPrompt != nil)
                                            ? { [rowRegenPrompt] in
                                                await actionVM.regenerateTapped(promptText: rowRegenPrompt)
                                            }
                                            : nil)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: row.isUser ? .trailing : .leading)
                        }
                        Color.clear
                            .frame(height: vm.bottomBuffer)
                            .id(TranscriptViewModel.bottomAnchorID)
                    }
                    .frame(maxWidth: Tokens.Layout.transcriptMaxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Tokens.Layout.gutter)
                    .padding(.top, Tokens.Spacing.m)
                }
                // The animated indicator lives OUTSIDE the lazy stack: its
                // 30 fps orbital ticks inside the lazy stack re-measured every
                // rich card each frame (QA-lane samples: 100% main thread
                // while a stalled stream kept the indicator up).
                .overlay(alignment: .bottomLeading) {
                    workingIndicator
                        .padding(.horizontal, Tokens.Layout.gutter)
                        .padding(.bottom, 6)
                }
                // Chats open at the newest message (ChatGPT); only the
                // INITIAL offset is anchored, so growth never yanks a reader
                // who scrolled up (§5).
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                // §5 "at bottom" from the real scroll geometry (an eager
                // stack's anchor onAppear fires once, not on visibility).
                // Written to a non-published property: no re-render.
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.visibleRect.maxY >= geometry.contentSize.height - 48
                } action: { _, atBottom in
                    vm.isAtBottom = atBottom
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
        .background(Tokens.Palette.canvas)
        // Dragging the conversation puts the keyboard away (ChatGPT feel).
        // Without it nothing could dismiss the keyboard once the composer
        // had focus — it permanently covered half the transcript.
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .accessibilityIdentifier("transcript.scrollView")
        .onAppear { vm.markBottomBufferNeeded() }
    }

    /// §2: brand label at the conversation head (assistant never bubbles).
    /// Static mark — passive surfaces never animate (brand kit).
    private var conversationHead: some View {
        HStack(spacing: Tokens.Spacing.s) {
            OrbitalCoreView(state: .idle, isStatic: true)
                .frame(width: 22, height: 22)
            Text("JARVIS")
                .font(.caption2.weight(.heavy))
                .tracking(1.6)
                .foregroundStyle(Tokens.Palette.textMuted)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("transcript.conversationHead")
    }

    /// Empty conversation: minimal welcome (03 "new chat suggestion text
    /// minimal"), the static Orbital Core mark, no extra feature pages.
    private func welcome(minHeight: CGFloat) -> some View {
        VStack(spacing: 14) {
            OrbitalCoreView(state: .idle, isStatic: true)
                .frame(width: 72, height: 72)
            Text("What can I help you with?")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Tokens.Palette.textPrimary)
                .multilineTextAlignment(.center)
            Text("JARVIS, ready when you are.")
                .font(.subheadline)
                .foregroundStyle(Tokens.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("transcript.welcome")
    }

    /// Item 9: the last USER prompt above `upTo` — the regenerate replay
    /// payload (nil when the exchange has no upstream user turn).
    private func lastUserPrompt(rows: [TranscriptRow], upTo index: Int) -> String? {
        for row in rows[..<index] where row.isUser {
            let trimmed = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return row.text }
        }
        return nil
    }

    /// §3 working indicator while the tail is open but has no text yet —
    /// the Orbital Core in its real `thinking` state (driven by isStreaming).
    @ViewBuilder
    private var workingIndicator: some View {
        if vm.isStreaming,
           vm.displayRows.last?.text.isEmpty ?? false {
            HStack(spacing: 8) {
                // Static mark: a continuously animating orbital forced a full
                // render + layout pass of the rich transcript every frame for
                // as long as a stream stayed open (100% main thread in the QA
                // lane). Brand kit: animate only on voice/status surfaces.
                OrbitalCoreView(state: .thinking, isStatic: true)
                    .frame(width: 22, height: 22)
                Text("JARVIS is working…")
                    .font(.footnote)
                    .foregroundStyle(Tokens.Palette.textSecondary)
            }
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(Tokens.Palette.elevated))
            .overlay(
                Capsule().strokeBorder(Tokens.Palette.border, lineWidth: 1))
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("transcript.workingIndicator")
        }
    }
}

/// One row: user = right-aligned deep-surface bubble ≤85% width; assistant =
/// full-width, no bubble (UI Law §2 — never bubble the assistant).
/// Item 11: an assistant row whose content carries a rich envelope renders
/// its typed blocks (additive; plain rows are untouched).
struct TranscriptRowView: View {
    let row: TranscriptRow
    let availableWidth: CGFloat
    var onRetry: (() -> Void)? = nil
    /// Item 11: injected by the transcript host (app owns the interaction
    /// store + handlers); nil = plain-text row exactly as Item 8 shipped.
    var richBlocks: [RichBlock]? = nil
    var richInteractions: RichInteractionStore? = nil
    /// The chat's send path for rich interactions (nil = local only).
    var onSendText: ((String) -> Void)? = nil

    init(row: TranscriptRow, availableWidth: CGFloat, onRetry: (() -> Void)? = nil,
         richBlocks: [RichBlock]? = nil,
         richInteractions: RichInteractionStore? = nil,
         onSendText: ((String) -> Void)? = nil) {
        self.row = row
        self.availableWidth = availableWidth
        self.onRetry = onRetry
        self.richBlocks = richBlocks
        self.richInteractions = richInteractions
        self.onSendText = onSendText
    }

    /// The row's rich payload: the VM-extracted map (parsed once per refresh,
    /// QA-pinned in Item11RichBlocksQATests), falling back to a direct parse
    /// for call sites that pass blocks without a host VM. nil = plain text.
    var richContent: [RichBlock]? {
        if richBlocks != nil { return richBlocks }
        guard !row.isUser else { return nil }
        return RichContentPayload.parse(row.text)
    }

    var body: some View {
        if row.isUser {
            userBubble
        } else {
            assistantBlock
        }
    }

    private var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: Tokens.Radius.bubble,
            bottomLeadingRadius: Tokens.Radius.bubble,
            bottomTrailingRadius: Tokens.Radius.bubbleTail,
            topTrailingRadius: Tokens.Radius.bubble,
            style: .continuous)
    }

    private var userBubble: some View {
        HStack(alignment: .bottom) {
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Text(row.text)
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.textPrimary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(bubbleShape.fill(Tokens.Palette.raised))
                    .overlay(bubbleShape.stroke(Tokens.Palette.border.opacity(0.6), lineWidth: 0.5))
                if row.status == .sending {
                    Text("Sending…")
                        .font(.caption2)
                        .foregroundStyle(Tokens.Palette.textMuted)
                }
                if row.status == .failed {
                    Text("Not delivered")
                        .font(.caption2)
                        .foregroundStyle(Tokens.Palette.danger)
                }
            }
            .frame(maxWidth: availableWidth * Tokens.Bubble.maxWidthFraction,
                   alignment: .trailing)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcript.message.\(row.id)")
    }

    private var assistantBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Full-width, no bubble (§2). A rich row renders its blocks
            // INSTEAD of the raw envelope: printing the text too put the
            // ```jarvis-rich JSON source above every card (QA screenshots).
            // The action row's copy still copies the verbatim row text.
            if richContent == nil {
                if row.text.isEmpty {
                    Text(" ")
                        .font(Tokens.Typography.body)
                } else {
                    MarkdownText(row.text)
                }
            }
            if let blocks = richContent,
               let interactions = richInteractions {
                RichBlocksView(
                    blocks: blocks,
                    messageID: row.id,
                    interactions: interactions,
                    onSend: onSendText)
            }
            if row.status == .failed {
                HStack(spacing: Tokens.Spacing.s) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.caption)
                    Text("Failed")
                        .font(.caption)
                    if row.retryAvailable {
                        Button("Retry") {
                            Task { await retry() }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Tokens.Palette.accent)
                        .frame(minHeight: Tokens.Layout.hitTarget)
                        .accessibilityIdentifier("transcript.retry")
                    }
                }
                .foregroundStyle(Tokens.Palette.danger)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcript.message.\(row.id)")
    }

    private func retry() {
        onRetry?()
    }
}
