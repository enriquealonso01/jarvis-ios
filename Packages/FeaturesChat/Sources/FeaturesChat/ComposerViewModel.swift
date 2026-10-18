import Foundation
import Persistence
import DesignSystem

// MARK: - Item 4: Composer view model (feature #3, P0)
//
// Store-backed @MainActor view model implementing the tester-pinned contract
// (Item4ComposerQATests @ 38a9ae8): content-gated send, >5k paste → chip,
// opt-in tool chips never silent, 5-line growth cap then internal scroll,
// long-press send → .showModelChooser, waveform → .startCall, ＋ sheet =
// exactly Photos/Camera/Files/HermesFiles in that order (UI Law §6).
//
// Send is local-first: the user row persists to the GRDB store even offline
// (outbox replay is the coordinator's job, not the composer's). Pure logic —
// no UIKit/SwiftUI; deterministic time via the injected clock so send rows
// are reproducible in tests.
@MainActor
public final class ComposerViewModel: ObservableObject {

    // MARK: Pinned contract constants

    /// Growth cap before the composer scrolls internally (UI Law §6 pins
    /// ~5–6 lines; the QA suite pins exactly 5).
    public static let maxLines: Int = 5

    // MARK: Dependencies

    private let store: PersistenceStore?
    /// Deterministic clock (tester contract; production = Date.init).
    private let clock: () -> Date
    /// Intent sink — the app target wires the call surface / chooser here.
    private let events: ((ComposerEvent) -> Void)?
    /// Model catalog the chip toggles resolve against (unknown ids are
    /// rejected — toggling never selects a different model).
    private let models: [ComposerModelOption]
    /// Conversation sends target. Assigned by the chat surface on selection;
    /// defaults to a fresh UUID so local-first sends always have a target.
    public var conversationID = UUID()

    // MARK: Published state

    /// Field content. Send enablement = non-whitespace content only.
    @Published public var text: String = ""
    /// Attachment chips (large pastes + ＋ sheet picks). Consumed on send.
    @Published public private(set) var attachments: [ComposerAttachment] = []
    /// Opt-in tool/model chips — empty at init, never silently populated.
    @Published public private(set) var selectedModels: [ComposerModelOption] = []
    @Published public private(set) var isSheetPresented: Bool = false
    /// True while the conversation is streaming (send → stop affordance per
    /// UI Law §3; the composer disables send while busy).
    @Published public private(set) var isStreaming = false

    // MARK: Item 5 auto-title feed (UI Law §8)

    /// Monotonic counter of successful local sends. The chat surface observes
    /// this to run the first-exchange auto-title rule against the
    /// conversation row (firing is decided by ListMechanicsEngine — only a
    /// still-default title + a user message retitles).
    @Published public private(set) var sentMessageCount = 0
    /// Role of the last sent row (auto-title only consumes user sends).
    @Published public private(set) var lastSentRole: MessageRole?
    /// Verbatim content of the last sent row (auto-title source text).
    @Published public private(set) var lastSentText: String?

    // MARK: Derived outputs (pinned contract)

    /// Send enables ONLY with non-whitespace text content. Chips and
    /// attachments are context — they never enable send by themselves.
    public var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Chips present → the chip row renders (opt-in, never silent).
    public var isChipAreaVisible: Bool {
        !selectedModels.isEmpty
    }

    /// Beyond `maxLines` the composer stops growing and scrolls internally.
    public var isScrollable: Bool {
        lineCount > Self.maxLines
    }

    /// Number of text lines (every "\n" starts a new line, including empty
    /// trailing lines — the growth math matches what the field renders).
    private var lineCount: Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// Points per text line — the view's layout math matches this so the
    /// pure growth cap and the SwiftUI layout agree.
    public static let lineHeight: CGFloat = 20

    /// Required field height: grows line by line up to `maxLines`, then
    /// stays (the field scrolls internally instead).
    public var fieldHeight: CGFloat {
        CGFloat(min(max(1, lineCount), Self.maxLines)) * Self.lineHeight
    }

    /// The ＋ sheet's row payload: exactly Photos/Camera/Files/HermesFiles
    /// in that display order (UI Law §6).
    public var sheetOptions: [ComposerSheetOption] { ComposerSheetOption.standard }

    /// The one-off model chooser's payload (long-press send). Separate list
    /// from the selected chips — the catalog never leaks into selection.
    public var chooserOptions: [ComposerModelOption] { models }

    // MARK: Init (pinned contract signature)

    public init(store: PersistenceStore? = nil,
                models: [ComposerModelOption] = ComposerModelOption.defaults,
                clock: @escaping () -> Date = Date.init,
                events: ((ComposerEvent) -> Void)? = nil) {
        self.store = store
        self.models = models
        self.clock = clock
        self.events = events
    }

    // MARK: - Input (pinned contract)

    /// Paste entry point (UI Law §6): > threshold auto-converts to ONE
    /// attachment chip carrying the full verbatim payload and the composer
    /// text is cleared. Exactly-at-threshold stays inline (strict >).
    public func onPaste(text pasted: String) {
        if pasted.count > Tokens.Composer.largePasteThreshold {
            attachments.append(ComposerAttachment.fromLargePaste(pasted))
            self.text = ""
        } else {
            self.text += pasted
        }
    }

    /// Chip toggle. Opt-in: adds the labeled chip on first tap, removes it
    /// on second. Unknown ids (outside the catalog) are rejected — toggling
    /// never selects a different model (§6: never silent, never wrong).
    public func toggle(modelID: String) {
        guard let option = models.first(where: { $0.id == modelID }) else { return }
        if let index = selectedModels.firstIndex(where: { $0.id == modelID }) {
            selectedModels.remove(at: index)
        } else {
            selectedModels.append(option)
        }
    }

    /// The × affordance: clear ALL tool chips; the chip row hides with them.
    public func clearChips() {
        selectedModels.removeAll()
    }

    /// Remove one attachment chip by id (per-chip × affordance).
    public func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    /// Long-press send: fire the one-off model-chooser intent. A gesture,
    /// not a send — never mutates composer state or writes rows.
    public func sendLongPressed() {
        events?(.showModelChooser)
    }

    /// Waveform button: START A CALL (UI Law §7) — never a dictation mode.
    /// Writes nothing, consumes no draft.
    public func waveformTapped() {
        events?(.startCall)
    }

    // MARK: - ＋ sheet

    /// ＋ button: open the bottom sheet.
    public func plusTapped() {
        isSheetPresented = true
    }

    /// Explicit dismissal (scrim tap, swipe, row-system dismiss).
    public func dismissSheet() {
        isSheetPresented = false
    }

    /// Sheet row tap: dismiss the sheet, stage an attachment chip so the tap
    /// is never silent (real pickers replace the placeholder in Item 6).
    /// Sheet rows are attachment pickers — NEVER model chips.
    public func selectSheetOption(_ option: ComposerSheetOption) {
        isSheetPresented = false
        attachments.append(ComposerAttachment(
            text: option.label, source: .picker))
    }

    // MARK: - Item 6: real-picker seam (feature #8, UI Law §6)
    //
    // The pinned VM contract above is untouched. Real pickers (app-target
    // thin wrappers: PhotosPicker / camera / fileImporter) call `record`
    // with a pure `ComposerAttachments.PickedItem` + the sheet row that
    // launched them; this resolves budgets + dedupe and stages the chip.
    // `send()` now ALSO writes the `StoredAttachment` payload rows onto the
    // message (send-time previews per feature #8).

    /// Picked-item metadata by chip id (drive sizes + local paths for the
    /// send-time payload rows). Not part of the draft KV snapshot — file
    /// paths don't survive relaunch meaningfully; chips do.
    private(set) var pickedItems: [UUID: ComposerAttachments.PickedItem] = [:]

    /// Last staging rejection (surfaced by the view — a rejected pick is
    /// NEVER silent; the view clears it after presenting).
    @Published public private(set) var lastRejection: ComposerAttachments.Rejection?

    /// Record one picked item from a real picker. Returns the staging
    /// outcome: a staged chip (appended), a duplicate (existing chip id —
    /// nothing stacked), or a rejection (surfaced, nothing staged).
    @discardableResult
    public func record(_ item: ComposerAttachments.PickedItem) -> ComposerAttachments.Stage {
        let outcome = ComposerAttachments.stage(item: item, kind: "file", staged: attachments)
        switch outcome {
        case .staged(let chip):
            attachments.append(chip)
            pickedItems[chip.id] = item
        case .duplicate(let existingID):
            // A file-backed re-pick of the SAME document can carry a fresh
            // local path (copy moved) — refresh the metadata, not the chip.
            pickedItems[existingID] = item
        case .rejected(let rejection):
            lastRejection = rejection
        }
        return outcome
    }

    /// Clear a surfaced rejection (the view calls this after presenting).
    public func clearRejection() {
        lastRejection = nil
    }

    // MARK: - Send (content-gated, local-first)

    /// Send. Accepts only with non-whitespace content; writes one user row
    /// through the store (source of truth) and clears the field. Attachment
    /// chips are flattened into the stored row content (after the text,
    /// verbatim paste payloads) and consumed on success. Returns false on
    /// the empty/whitespace guard (a no-op — nothing written, nothing lost).
    @discardableResult
    public func send() async throws -> Bool {
        // Capture BEFORE any reset; trimmed content is what enables send,
        // but the row carries the draft verbatim (interior spacing kept).
        let draft = text
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let chips = attachments

        // One user row: draft text + verbatim paste payloads flattened.
        var content = draft
        for chip in chips where chip.source == .paste {
            if !content.isEmpty { content += "\n\n" }
            content += chip.text
        }

        // Item 6: picker/paste chips persist as StoredAttachment descriptors
        // on the row (image|file|paste kinds; paste chips ride inside content
        // AND declare their descriptor).
        var descriptors: [StoredAttachment] = []
        let imageExts = ["jpg", "jpeg", "png", "heic", "webp", "gif"]
        for chip in chips {
            switch chip.source {
            case .paste:
                descriptors.append(StoredAttachment(kind: "paste", name: chip.text))
            case .picker:
                let picked = pickedItems[chip.id]
                let ext = (chip.text as NSString).pathExtension.lowercased()
                let kind = imageExts.contains(ext) ? "image" : "file"
                descriptors.append(StoredAttachment(
                    kind: kind,
                    name: chip.text,
                    localPath: picked?.localPath))
            }
        }
        let row = StoredMessage(
            conversationID: conversationID,
            role: .user,
            content: content,
            status: .sending,
            createdAt: clock(),
            attachments: descriptors
        )
        if let store {
            // First send on a fresh chat creates the conversation row
            // (ChatGPT behavior: the chat is born with its first message).
            if await store.get(id: conversationID) == nil {
                let title = String(content.split(separator: "\n").first?.trimmingCharacters(in: .whitespaces) ?? "New chat")
                await store.upsert(StoredConversation(
                    id: conversationID,
                    title: title.isEmpty ? "New chat" : title,
                    createdAt: clock(),
                    updatedAt: clock(),
                    lastMessagePreview: content
                ))
            }
            await store.upsert(row)
        }

        text = ""
        attachments = []
        // Item 5 feed: publish the send facts AFTER the reset so observers
        // see a stable, already-written row.
        lastSentRole = MessageRole.user
        lastSentText = content
        sentMessageCount += 1
        return true
    }

    // MARK: - State restoration (survives restarts; Item 3 KV pattern)

    private enum Keys {
        static let draft = "v2.composer.draft"
    }

    /// Codable snapshot of the persisted part of the composer state.
    private struct DraftSnapshot: Codable, Equatable {
        var text: String
        var attachments: [ComposerAttachment]
        var selectedModels: [ComposerModelOption]
    }

    /// Restore the draft + chips from the store KV. Store-less init
    /// (previews/tests) is a no-op.
    public func restoreState() async {
        guard let store else { return }
        if let snapshot: DraftSnapshot = await store.appState(DraftSnapshot.self, key: Keys.draft) {
            text = snapshot.text
            attachments = snapshot.attachments
            selectedModels = snapshot.selectedModels
        }
    }

    /// Persist the draft + chips through the store KV (call after user
    /// mutations; explicit instead of `didSet` so pure-logic tests stay
    /// synchronous and store-free).
    public func persistDraft() async {
        guard let store else { return }
        let snapshot = DraftSnapshot(
            text: text,
            attachments: attachments,
            selectedModels: selectedModels)
        await store.setAppState(snapshot, key: Keys.draft)
    }
}
